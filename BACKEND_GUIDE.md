# ECT backend operations

## Flow and deployment

The phone decodes CAN/GPS and owns sessions/laps, commands and live display.
TelemetryRecorder assigns immutable context; TelemetryJournal commits it and
the checkpoint; MqttService sends committed pending records. The backend is
Mosquitto -> Telegraf -> validated SQL -> TimescaleDB read models -> Grafana.
Server CSV subscribes independently; local CSV exports committed journal rows.
See [the authoritative v2 contract](docs/contracts/telemetry-v2.md).

Both layouts use TimescaleDB 2.17.2/PG16, Telegraf 1.31.3, Grafana 11.1.4 and
Paho 2.1.0. The single image reuses official component binaries and adds
Supervisor/tini. Main component tags are pinned; OS/broker package rebuilds can
still change. Both layouts share one broker config and one Telegraf config.

~~~sh
docker build -t ect-backend -f ops/backend/Dockerfile .
docker run -d --name ect-backend --restart unless-stopped -p 1883:1883 -p 3000:3000 -p 8080:8080 -e POSTGRES_PASSWORD=your-db-password -e TELEGRAF_PASSWORD=your-ingest-password -e GRAFANA_READER_PASSWORD=your-reader-password -e GRAFANA_ADMIN_PASSWORD=your-admin-password ect-backend
~~~

For Compose, copy ops/local-stack/.env.example to .env in that directory, set
credentials, and run:

~~~sh
docker compose -f ops/local-stack/docker-compose.yml --env-file ops/local-stack/.env up -d --build
~~~

Use named mounts for reliable single-container replacement:
 /var/lib/postgresql/data, /var/lib/mosquitto, /var/lib/grafana and
 /var/lib/ect-backend/exports. Anonymous volumes survive ordinary restart but
must be explicitly reattached after replacing a container. Compose mounts
csv_exports on the host; its CSV entrypoint initializes ownership for uid/gid
65534, then drops privileges. CSV HTTP uses a read-only mount.

| Surface | Port | Role |
|---|---:|---|
| MQTT | 1883 | Phone handoff and persistent consumer subscriptions |
| PostgreSQL | 5432 | Optional direct access; phone never queries SQL |
| Grafana | 3000 | Session/lap dashboards and fresh-source alerts |
| CSV HTTP | 8080 | Read-only archive/snapshot download in both layouts |

Supplied broker/CSV services assume a trusted network. Read
[broker authentication/TLS guidance](ops/mosquitto/README.md) before exposing
them outside that network. CSV serving rejects symlink traversal outside its root.

## Environment

| Variables | Behavior |
|---|---|
| POSTGRES_DB / USER / PASSWORD | Dedicated DB bootstrap; development defaults telemetry/postgres/postgres |
| TELEGRAF_PASSWORD | telegraf_ingest password; development default telegraf |
| GRAFANA_READER_PASSWORD | grafana_reader password; development default grafana |
| GRAFANA_ADMIN_USER / PASSWORD | Grafana login; development defaults admin/admin |
| TS_HOST / PORT / DB / USER / PASSWORD | Single ingest overrides; defaults derive at runtime |
| TS_DATASOURCE_URL / USER / DB / PASSWORD | Single datasource overrides; defaults use reader/custom DB |
| TOPIC_EVENTS / TOPIC_SESSIONS | Consumer topics; phone currently uses the standard topics |
| TELEGRAF_EVENTS_CLIENT_ID / TELEGRAF_SESSIONS_CLIENT_ID / CSV_CLIENT_ID | Stable consumer identities; distinct deployments need distinct IDs |
| CSV_SERVER_PORT / EXPORT_DIR | Single CSV HTTP port/export root |
| TS_PORT / MQTT_PORT / GRAFANA_PORT / CSV_SERVER_PORT in Compose .env | Host mappings; internal service ports stay fixed |

MQTT_HOST/MQTT_PORT point consumers at their internal broker. Topics are
telemetry/eco_archers/events and telemetry/eco_archers/sessions. Explicit TS_*
overrides win for single-container consumers. Its baked-in ingest/datasource
credentials no longer mask custom bootstrap values. Grafana provisioning uses
plain environment interpolation; shell-style defaults belong to runtime wiring.

Changing POSTGRES_* on an existing volume does not rename its DB/users or change
stored passwords. Role setup runs during fresh initialization. Update credentials
deliberately in both DB roles and consumers.

## Schema and analytics

| Relation | Responsibility |
|---|---|
| schema_metadata | Version, source SHA-256 and initialization time |
| sessions | UUID, captured start/end and monotonic metadata revision |
| telemetry_raw / telemetry_samples | Typed hypertable and read surface |
| telemetry_ingest_view / sessions_ingest_view | TEXT-tag COPY adapters with validating triggers |
| ingest_rejections | Malformed/conflicting records and reasons |
| session_catalog | Discovery even when metrics precede metadata |
| latest_signals | Latest original observation and source freshness |
| accumulator_deltas / session_totals / lap_totals | Reset-safe main-energy/distance totals |
| lap_bounds | Explicit completion diagnostics/elapsed duration |
| telemetry_seconds / lap_analytics | Shared estimates and complete/in-progress laps |
| gps_fixes | Coordinates paired by source/fix identity |

telegraf_ingest can insert/select ingest views and read schema_metadata.
Security-definer triggers validate/cast into owned tables with a fixed search
path. grafana_reader reads designated surfaces with a 30-second query timeout.
Telemetry has no metadata FK: early metrics are intentionally valid.

The first accumulator sample is a baseline. A reset contributes its new
nonnegative value. Bucket estimates use available data without interpolating
missing sensors. An observed lap is not automatically completed. Sequence gaps
are provisional until delayed delivery is reconciled. Unsupported temperature
and auxiliary-energy panels are removed; live alerts check original source age
and current fault bitfields. Phone temperatures/cells are unavailable until
implemented, rather than synthetic numeric placeholders.

Telegraf 1.31.3 array timestamp_key repeats the first element timestamp. The
adapter carries each original ts_wall_utc as TEXT and casts it in SQL. Owned
timestamps/UUIDs/integers are typed. There is no unpivot, vehicle_setup JSON,
optional stored laps table or batch sequence range. New metric names need no
SQL column. DBC additions use the generator and can_bindings.dart.

## Initialization and existing volumes

Fresh-only schema/role initialization records a schema fingerprint. TCP
readiness excludes Postgres's temporary initialization socket. Single ingest
waits for a matching schema; Compose gates readers on DB health. Single health
also probes broker, CSV HTTP, Grafana and stable worker processes. Qualification
publishes through both subscriptions; process existence is insufficient.

Old/mismatched schema is unhealthy and preserved. Startup never silently drops
or upgrades it. Use the [explicit paired clean cutover](docs/implementation/cutover.md)
for this breaking release. Future upgrades need a versioned upgrade path.

For manual fresh bootstrap, set PGHOST/PORT/DATABASE/USER/PASSWORD plus
TELEGRAF_PASSWORD/GRAFANA_READER_PASSWORD and run
python tools/initialize_backend.py with psql installed. initialize_schema.sh/ps1
call the same implementation. Existing schema fails. The manual initializer configures the fixed telegraf_ingest/grafana_reader roles; use this dedicated backend cluster, since altering these roles in a shared cluster could affect other databases. The old apply_migrations
scripts were only fresh initializers and have been retired.

## Archives and repair

Server CSV flushes/fsyncs once per second and keeps duplicates; descriptor use
is bounded. Local CSV flushes before its journal export cursor advances and
repairs after failure/restart. An interrupted export can repeat rows.
ACKed journal history remains seven days and is pruned only after export.
Retention runs every 30 minutes; local CSV retention is configurable.

Pending JSON is capped at 256 MiB. Capture is bounded to 256 records, reserving
space for metadata/loss records. Quota/write failures are visible. Records
buffered before SQLite commit are not durable; recovery retains the last
committed elapsed offset and excludes downtime.

PUBACK means broker handoff, not SQL/CSV receipt or power-loss durability.
Mosquitto saves persistence each second; server CSV has an approximately
one-second buffered window. Real OS/device/fsync behavior still needs qualification.
SQL/consumer outages recover within finite queues: Telegraf buffers 20,000 metrics,
allows 250 undelivered messages per subscription, and the broker caps queued
offline messages at 10,000. Do not infer indefinite loss-free recovery.

Read-only SQL snapshots use the reader role:

~~~sh
docker exec ect-backend export_to_csv.sh
docker compose -f ops/local-stack/docker-compose.yml exec timescaledb python3 /ops/backend/export_snapshot.py --output /exports
~~~

Local export shell/PowerShell wrappers use the same Python implementation and
PG* overrides. Partial files are removed on failure.

~~~sh
python tools/reconcile_telemetry.py --expected phone-events.json sql-telemetry.csv
python tools/replay_csv.py events_v2_UUID.csv --session UUID --sql-snapshot sql-telemetry.csv
~~~

Replay defaults to dry-run. With Paho 2.1.0 installed, add --publish --host <broker>
to send missing validated metric records. Original identities/times are retained;
conflicting archives fail. Reconciliation compares all immutable metric context, normalizing SQL/CSV timestamp and numeric types; receipt time is excluded. Replay refuses conflicting SQL/archive identities. Reconcile again after replay. Metadata repair uses
versioned session records; this tool handles metrics only.

## Qualification and remaining gate

~~~sh
python -m unittest discover -s ops/backend -p 'test_*.py'
python -m unittest discover -s tools -p 'test_*.py'
python tools/qualify_backend.py --layout compose --report compose-report.json
python tools/qualify_backend.py --layout single --report single-report.json
~~~

Requires Docker, PyYAML 6.0.2 and Flutter with pub get complete. It creates unique
disposable resources/custom credentials, probes both consumers, checks malformed
neighbors, duplicates/conflicts, delayed metadata, freshness, reset totals,
all Grafana SQL under the reader role, real Grafana API, actual Dart CAN/SQLite/
MQTT, SQL/CSV reconciliation, fresh-only manual initialization, reader snapshots/failure cleanup, missing-record CSV repair, outages, restarts and compressed replay. It cleans
resources in finally; --keep-on-failure retains only its test target for diagnosis.
CI runs both layouts.

Synthetic tests establish software interoperability. Target Android/CAN, peak
hardware/UI behavior and background/permissions remain a separate gate.
Android SDK is unavailable on this validation host, so APK build is pending.
