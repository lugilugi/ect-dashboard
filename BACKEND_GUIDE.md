# ECT backend operations

## Flow and deployment

The phone decodes CAN/GPS and owns sessions/laps, commands and live display.
TelemetryRecorder assigns immutable context; TelemetryJournal commits it and
the checkpoint; MqttService sends committed pending records. The backend is
Mosquitto -> Telegraf -> SQL staging -> validated set-based ingest job ->
TimescaleDB read models -> Grafana.
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
| schema_metadata | Schema version 3 (contract ect.telemetry.v2), source SHA-256, initialization time |
| sessions | UUID, captured start/end and monotonic metadata revision |
| telemetry_raw / telemetry_samples | Typed hypertable and read surface |
| telemetry_observations | Original observations only (no sampler snapshots); plot by observed_at |
| telemetry_ingest / sessions_ingest | Plain TEXT-tag staging tables written by Telegraf COPY |
| ingest_staged job / ingest_status | 1 s set-based validation/merge; staged backlog and oldest age |
| ingest_rejections | Malformed/conflicting records and reasons |
| session_bounds / session_catalog | Ingest-maintained sample bounds; discovery even when metrics precede metadata |
| latest_session | Newest session across metadata and first samples (alerts); state NULL while metadata is in transit |
| latest_signal_values / latest_signals | Ingest-maintained latest value per session/signal; view adds source freshness |
| accumulator_deltas / session_totals / lap_totals | Reset-safe main-energy/distance totals over observations |
| lap_bounds | Explicit completion diagnostics/elapsed duration |
| observation_intervals / telemetry_seconds / lap_analytics | Time-weighted shared estimates and complete/in-progress laps |
| gps_fixes | Coordinates paired by source/fix identity |

telegraf_ingest can insert/select the staging tables and read schema_metadata;
it cannot write owned tables or run the ingest functions. The owner's
TimescaleDB jobs run ingest_staged every second (each job's next run starts
1 s after its previous one finishes). There are two identical jobs because
TimescaleDB 2.17 holds a job whose worker a PostgreSQL stop, restart or crash
killed mid-run for at least 5 minutes (a fixed minimum; retry_period does not
shorten it). Only one run holds the ingest lock at a time, and the other job's
runs return within milliseconds, so a restart leaves a survivor that keeps
ingesting at once. Its first locked run replaces a held sibling (a crashed run
that started before the current job scheduler) with a fresh job, so a second
restart soon after again finds a survivor. Each locked run claims the oldest committed staging rows (up
to 20,000 per transaction) with DELETE ... RETURNING, validates every cast and
CHECK in one pass (pg_input_is_valid on PG16), probes the identity unique
index for each batch identity, inserts only identities not already stored
(ON CONFLICT DO NOTHING remains a backstop), compares redeliveries with the
stored row or first batch arrival, quarantines invalid rows and conflicting
duplicates in ingest_rejections (received_at = staging time), and upserts
latest_signal_values and session_bounds in the same statement. The insert
never targets an existing key: on TimescaleDB 2.17 a multi-row ON CONFLICT
that hits a compressed chunk can drop or hide other rows of the statement.
An invariant (inserted + redelivered + invalid = claimed) raises and rolls the
batch back, leaving rows staged, rather than losing data silently. Rows a Telegraf COPY has not committed stay staged for the next
run; an advisory lock serializes the jobs with manual CALL ingest_staged(), so
no row is processed twice or lost. A manual CALL waits for the lock and drains
everything; a scheduled run that finds it held returns. A restart that kills
both jobs mid-run at once (the holder's batch and the other job's
millisecond run) still delays SQL ingest by about 5 minutes; rows stay staged
or queued and are not lost. If a batch still hits a data error, that
batch is retried row by row so only the offending row is quarantined.
Operational errors roll back and leave rows staged for retry. A stopped job
shows as growing ingest_status backlog and, while logging, the stall alert.
grafana_reader reads designated surfaces with a 30-second query timeout.
Telemetry has no metadata FK: early metrics are intentionally valid.
telemetry_raw chunks compress after 2 days, so ordinary late phone uploads land
in uncompressed chunks. Later redelivery or gap repair into compressed chunks,
including batches mixing stored and new rows, is idempotent and lossless
(qualified); each stored-row probe into a compressed chunk decompresses the
matching segment, so large replays into old data are slower than live ingest.

The first accumulator sample is a baseline. A reset contributes its new
nonnegative value. Analytics use original observations only: sampler snapshots
are excluded from telemetry_seconds, lap statistics and accumulator deltas.
Each observation holds its value until that signal's next observation, capped
at its freshness_ms, so change-suppressed steady values keep their time weight
and outages are never interpolated; a non-ok observation ends the hold.
telemetry_seconds is a time-weighted regular view rather than a continuous
aggregate, because hold intervals need window functions; per-session queries
push the session filter into the index. A second split by a lap boundary or
an outage yields a partial row; telemetry_seconds exposes speed/power/throttle
coverage seconds, and lap statistics, shares and distributions weight by them.
An observed lap is not automatically completed. Sequence gaps
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

Fresh-only schema/role initialization records schema version 3 and a schema
fingerprint. TCP
readiness excludes Postgres's temporary initialization socket. Single ingest
waits for a matching schema; Compose gates readers on DB health. Single health
also probes broker, CSV HTTP, Grafana and stable worker processes. Qualification
publishes through both subscriptions; process existence is insufficient.

Old/mismatched schema is unhealthy and preserved. Startup never silently drops
or upgrades it. Use the [explicit clean cutover](docs/implementation/cutover.md) for the
schema 2 -> 3 server reset (wire contract unchanged). Future upgrades need a versioned upgrade path.

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
MQTT, SQL/CSV reconciliation, fresh-only manual initialization, reader snapshots/failure cleanup, missing-record CSV repair, outages, restarts, compressed replay and a database
restart that kills an ingest run mid-batch (ingest must resume within 60 s). It cleans
resources in finally; --keep-on-failure retains only its test target for diagnosis.
CI runs both layouts.

Synthetic tests establish software interoperability. Target Android/CAN, peak
hardware/UI behavior and background/permissions remain a separate gate.
Android SDK is unavailable on this validation host, so APK build is pending.
