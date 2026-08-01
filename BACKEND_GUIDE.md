# ECT Dashboard: Backend Setup, Configuration & CAN Signal Guide

How to run your own ECT telemetry backend, point the Flutter app at it, and
add or remove CAN messages/signals without touching the database.

---

## 1. System Architecture

The ECT Dashboard backend collects sparse JSON telemetry published by the
Flutter app over MQTT and stores it in a time-series database for dashboards:

```
[Flutter App (USB/CAN)] --MQTT sparse JSON--> [Mosquitto (broker)]
                                                        |
                                          (Telegraf subscribes)
                                                        v
                              [TimescaleDB (PostgreSQL)] <-- (Telegraf inserts)
                                        |
                          (Grafana queries)
                                        v
                              [Dashboards]
```

| Component      | Port  | Role                                                        |
| -------------- | ----- | ----------------------------------------------------------- |
| **Mosquitto**  | 1883  | MQTT broker; the app publishes sparse JSON batches here.    |
| **Telegraf**   | –     | Subscribes to MQTT, parses JSON, unpivots to EAV rows, inserts into TimescaleDB. |
| **TimescaleDB**| 5432  | Time-series PostgreSQL; one row per signal sample.          |
| **Grafana**    | 3000  | Dashboards and lap analysis.                                |

The database schema is **shape-agnostic** (narrow EAV rows: `signal_name` /
`value`), so new CAN signals flow into the backend **with zero schema
changes** — see [Section 6](#6-adding--removing-can-messages--signals--topics).

---

## 2. Deployment Options

There are two equivalent ways to run the backend. Pick whichever fits:

- **Option A — Single container** ([ops/backend](ops/backend)): the whole
  stack in one image driven by supervisord. `docker build` + `docker run`,
  no Compose. Easiest for other people to stand up.
- **Option B — Compose stack** ([ops/local-stack](ops/local-stack)): one
  container per service, easier to scale/replace individually.

Both use the same schema, the same provisioning files, and the same
environment-variable configuration.

### Option A: Single container (recommended for most setups)

Requires Docker (with BuildKit, standard since Docker 23+). Build from the
repository **root** (the whole repo is the build context):

```bash
cd ect-dashboard
docker build -t ect-backend -f ops/backend/Dockerfile .
```

Run it — override anything with `-e`:

```bash
docker run -d --name ect-backend \
  -p 1883:1883 -p 5432:5432 -p 3000:3000 \
  -e POSTGRES_PASSWORD=your_db_password \
  -e GRAFANA_ADMIN_PASSWORD=your_grafana_password \
  ect-backend
```

That's it. On first boot the container initializes the database and applies
[db/schema.sql](db/schema.sql) automatically. Check readiness:

```bash
docker logs -f ect-backend          # watch supervisord start all 4 services
docker exec ect-backend supervisorctl status
```

| Service   | How to reach it from outside                       |
| --------- | -------------------------------------------------- |
| MQTT      | `mqtt://<host>:1883`                                |
| TimescaleDB | `postgresql://postgres:<password>@<host>:5432/telemetry` |
| Grafana   | `http://<host>:3000` — log in with `GRAFANA_ADMIN_USER` / `GRAFANA_ADMIN_PASSWORD` |

The app's MQTT settings (host/port, topics) are configured in **Service
mode → Config → MQTT**.

### Option B: Compose stack

```bash
cd ops/local-stack
cp .env.example .env        # optional: adjust credentials/ports
docker compose up --build -d
```

Stop and wipe everything (fresh database):

```bash
docker compose down -v
```

---

## 3. Configuration Reference (Environment Variables)

Both deployment options read the same variables. The single-container image
ships safe local defaults (set via `ENV` in the Dockerfile); Compose passes
them through [`.env`](ops/local-stack/.env.example). Override with
`docker run -e VAR=value` or in `.env`.

| Variable                | Default                          | Meaning                                   |
| ----------------------- | -------------------------------- | ----------------------------------------- |
| `POSTGRES_DB`           | `telemetry`                      | Database name (also used by Telegraf/Grafana). |
| `POSTGRES_USER`         | `postgres`                       | Database user.                            |
| `POSTGRES_PASSWORD`     | `postgres`                       | **Change in production.**                 |
| `GRAFANA_ADMIN_USER`    | `admin`                          | Grafana admin login.                      |
| `GRAFANA_ADMIN_PASSWORD`| `admin`                          | Grafana admin password. **Change in production.** |
| `TOPIC_EVENTS`          | `telemetry/eco_archers/events`   | MQTT topic the app publishes telemetry batches to. |
| `TOPIC_SESSIONS`        | `telemetry/eco_archers/sessions` | MQTT topic for session metadata.          |
| `MQTT_HOST` / `MQTT_PORT` | `127.0.0.1` / `1883`           | Broker address Telegraf subscribes to (Compose: `mosquitto`). |
| `TS_HOST` / `TS_PORT`   | `127.0.0.1` / `5432`             | Database address Telegraf writes to (Compose: `timescaledb`). |
| `TS_DB` / `TS_USER` / `TS_PASSWORD` | `telemetry` / `postgres` / `postgres` | Telegraf database credentials. |
| `TS_DATASOURCE_URL`     | `localhost:5432` (single) / `timescaledb:5432` (Compose) | Grafana datasource URL. |
| `TS_DATASOURCE_USER/DB/PASSWORD` | `postgres` / `telemetry` / `postgres` | Grafana datasource credentials. |
| `TS_PORT` / `MQTT_PORT` / `GRAFANA_PORT` (Compose) | `5432` / `1883` / `3000` | **Host** port bindings. |

**App side:** set the same broker host/port in the app (Service → Config →
MQTT). The app publishes to `TOPIC_EVENTS` and `TOPIC_SESSIONS` — if you
override the topics, update the app or point a broker-level topic rewrite at
the defaults.

---

## 4. MQTT Contract

### Topics

| Topic                            | Publisher | Payload                                        |
| -------------------------------- | --------- | ---------------------------------------------- |
| `telemetry/eco_archers/events`   | App       | Sparse JSON batch of changed signal values     |
| `telemetry/eco_archers/sessions` | App       | Session metadata (upserted into `sessions`)    |

Topics are configurable (`TOPIC_EVENTS` / `TOPIC_SESSIONS`) so teams can
namespace their own deployment (e.g. `telemetry/my_team/events`).

### Events payload (sparse batch)

The app batches only *changed* values into one JSON object per publish:

```json
{
  "session_uid": "1a2b…",
  "lap_number": 3,
  "ts_wall_utc": "2026-08-01T04:00:00.000Z",
  "ts_session_ms": 654321,
  "seq_in_session_start": 123,
  "seq_in_session_end": 156,
  "Speed_Kmh": 42.5,
  "Voltage_780": 41.2
}
```

- `session_uid`, `lap_number`, `ts_session_ms`, `seq_in_session_start/end`
  become tags (segment keys).
- `ts_wall_utc` becomes the metric timestamp (so outage replays keep original
  timing).
- Every other key is a **signal** → one EAV row: `signal_name` = key,
  `value` = number.

### Sessions payload

```json
{ "uid": "…", "session_name": "Day 1 - Run 2", "vehicle_setup": "{…}" }
```

Telegraf inserts through the `sessions_ingest_view` writable view, which
upserts on `uid` — safe to publish repeatedly. Only `uid` and
`session_name` are ingested; `vehicle_setup` (a nested object) is not
supported by the `json_v2` parser and is skipped (see [Section 7](#7-database-schema-overview)).

---

## 5. CAN Signal Registry

**The single source of truth for every signal the app publishes is
[`lib/models/telemetry/can_signal_registry.dart`](lib/models/telemetry/can_signal_registry.dart).**
The backend is a pure EAV sink — it stores *any* `signal_name` you give it —
so the registry is the contract between the app and the dashboards.

| CAN ID | Message           | Signal                 | Unit  |
| ------ | ----------------- | ---------------------- | ----- |
| `0x110`| Pedal Input       | `Throttle_Percent`     | %     |
| `0x110`| Pedal Input       | `Brake_Active`         | bool  |
| `0x310`| Power Monitor 780 | `Voltage_780`          | V     |
| `0x310`| Power Monitor 780 | `Current_780`          | A     |
| `0x311`| Power Monitor 740 | `Voltage_740`          | V     |
| `0x311`| Power Monitor 740 | `Current_740`          | A     |
| `0x312`| Energy Counter    | `Joules_780`           | J     |
| `0x312`| Energy Counter    | `Joules_740`           | J     |
| `0x400`| Dashboard Status  | `Error_Count`          | count |
| `0x400`| Dashboard Status  | `MC_Temp_C`            | C     |
| `0x400`| Dashboard Status  | `Batt_Temp_C`          | C     |
| `0x500`| Hall Speed/Dist   | `Speed_Kmh`            | km/h  |
| `0x500`| Hall Speed/Dist   | `Distance_Km`          | km    |
| `0x510`| GPS Fix           | `GPS_Satellites`       | count |
| `0x510`| GPS Fix           | `GPS_Locked`           | bool  |
| `0x510`| GPS Fix           | `GPS_Fallback_Active`  | bool  |
| `0x510`| GPS Fix           | `GPS_Fallback_Period_Ms` | ms  |
| `0x511`| GPS Position      | `GPS_Latitude_Deg`     | deg   |
| `0x511`| GPS Position      | `GPS_Longitude_Deg`    | deg   |
| `0x512`| GPS Motion        | `GPS_Speed_Kmh`        | km/h  |
| `0x512`| GPS Motion        | `GPS_Heading_Deg`      | deg   |

Signal names use `CamelCase` with units as suffixes (`_C`, `_Kmh`, `_Deg`).
Phone-GPS fallback reuses the same `GPS_*` names with a `phone_gps` source,
so external and fallback GPS plot on the same series. CAN IDs live in
[`CanMsgID`](lib/models/telemetry/can_messages.dart).

---

## 6. Adding / Removing CAN Messages, Signals & Topics

### Adding a new signal to an existing CAN message (easiest — no ID change)

1. **App:** add a `CanSignalSpec` entry to `canSignalRegistry`
   (`lib/models/telemetry/can_signal_registry.dart`).
2. **App:** in `UsbService._dispatchPayload`
   (`lib/services/ingest/usb_service.dart`), add the value to that CAN ID's
   `_publishSignals(id, {...})` map.
3. Done — the backend ingests it automatically (EAV schema), and Grafana
   queries it by `signal_name` in the existing dashboards.

### Adding a brand-new CAN message (new ID)

1. **App:** add the ID to `CanMsgID` (`lib/models/telemetry/can_messages.dart`)
   and a decoder class next to the other `*Payload` classes.
2. **App:** add one `CanSignalSpec` per signal to `canSignalRegistry`.
3. **App:** add a `case` to `UsbService._dispatchPayload` that decodes the
   payload and calls `_publishSignals(canId, {signal: value})`.
4. **Backend:** nothing to change. Optionally add a Grafana panel querying the
   new `signal_name`.

### Removing a signal or message

1. Delete its `CanSignalSpec` entry(ies) and its entries in
   `_dispatchPayload`.
2. Delete the CAN ID from `CanMsgID` if the whole message goes away.
3. Historical rows stay in the database (they are just data), new batches
   simply stop carrying the field.

### Adding a new MQTT topic (beyond events/sessions)

1. **Backend:** add an `[[inputs.mqtt_consumer]]` block to the Telegraf
   config (`ops/backend/telegraf.conf` or
   `ops/local-stack/telegraf/telegraf.conf`) pointing at a new env var, e.g.
   `topics = ["${TOPIC_COMMANDS}"]`.
2. **Backend:** export the variable — `-e TOPIC_COMMANDS=…` for the
   single container, or an `environment:` entry / `.env` line for Compose.
3. **App:** publish to that topic from wherever you like
   (`MqttService` exposes `publish(topic:payloadJson:)` on the transport).

> Rule of thumb: **signals never need schema changes.** Only a brand-new
> *message family* (e.g. `commands`) would justify a new Telegraf input.

---

## 7. Database Schema Overview

All database definitions are consolidated in [db/schema.sql](db/schema.sql).

The schema follows a narrow Entity-Attribute-Value (EAV) design. Every CAN
message becomes a single row per signal, so the pipeline stays
shape-agnostic: irregular or differently-shaped CAN messages never require
schema changes.

### Core Tables

1. **`sessions`**: Metadata for active runs (UUID `uid`, `session_name`,
   `created_at`, `vehicle_setup` JSONB).
2. **`laps`**: Lap sequence numbers and boundaries (`lap_number`,
   `started_at`, `ended_at`). Linked to `sessions(uid)` via FK.
3. **`telemetry_raw`** (Hypertable): The narrow time-series sink — one row
   per signal sample:
   - `time` (TIMESTAMPTZ) — the wall-clock capture time from the app payload.
   - `session_uid`, `lap_number`, `ts_session_ms`, `seq_in_session_start`,
     `seq_in_session_end` (**TEXT**) — segment keys.
   - `signal_name` (TEXT), `value` (DOUBLE PRECISION) — the EAV pair
     (e.g. `'Speed_Kmh'`, `'Voltage_780'`).

> **Why the segment keys are TEXT:** Telegraf's `outputs.postgresql` plugin
> (≥1.31) writes metrics via `COPY … FROM STDIN BINARY`, encoding every
> **tag** as a string against the column's declared type. Pre-created tables
> whose tag columns are `uuid`/`int`/`bigint` fail with
> `08P01: insufficient data left in message` (or `22P03: incorrect binary
> data format`). Tags must therefore be TEXT columns here; cast in queries
> when you need numeric semantics, e.g. `lap_number::int`,
> `ts_session_ms::bigint` (see [Section 10](#10-grafana-custom-queries--performance)).
>
> **Performance impact: none in practice.** The hot columns are untouched:
> `time` (TIMESTAMPTZ) drives hypertable chunk pruning, `value`
> (DOUBLE PRECISION) does all aggregation, and `signal_name` was always
> TEXT. Dashboard filters like `session_uid::text = '…'` are equality on a
> TEXT column — the `::text` cast is a no-op that the planner strips, so the
> `idx_telemetry_lookup` index is still used (verified with `EXPLAIN`). The
> only casts needed are for ordering/arithmetic (`lap_number::int`,
> `ts_session_ms::bigint`), which run on already-filtered result sets.

### Writable View

**`sessions_ingest_view`** exposes `uid` (TEXT — the plugin writes it as a
string), `session_name`, `vehicle_setup`, `time`. An `INSTEAD OF INSERT`
trigger casts `uid` back to `UUID` and upserts into `sessions` on `uid`, so
Telegraf can publish session metadata idempotently.

> `vehicle_setup` (JSONB) is deliberately **not** ingested through this
> pipeline: Telegraf `json_v2` cannot stringify a nested JSON object into a
> single field (it would flatten it into `vehicle_setup_*` fields and
> clobber the whole metric batch), so the column stays in the base table for
> manual/API use. The ingest contract is `uid` + `session_name` only.

### Ingestion Pipeline (sparse payload → EAV)

1. The app batches changed metric values and publishes a sparse JSON object
   per batch (see [Section 4](#4-mqtt-contract)).
2. Telegraf `json_v2` parses it, tags the metadata (`session_uid`,
   `lap_number`, `ts_session_ms`, `seq_in_session_start`,
   `seq_in_session_end`), uses `ts_wall_utc` as the metric timestamp, and
   emits the remaining fields as fields.
3. The `[[processors.unpivot]]` processor turns each field into an EAV row
   (`signal_name` = key, `value` = numeric value) under the `telemetry_raw`
   measurement.
4. Replayed/backfilled batches keep their original `ts_wall_utc` timestamps,
   so order and timing survive outage recovery.

---

## 8. Verifying the Pipeline

Everything healthy? From inside the container:

```bash
docker exec ect-backend supervisorctl status
# postgres  RUNNING ...  mosquitto RUNNING ...  telegraf RUNNING ...  grafana RUNNING
```

Watch live rows as the app logs:

```sql
docker exec -it ect-backend psql -U postgres -d telemetry
SELECT count(*) FROM telemetry_raw;
SELECT signal_name, count(*) FROM telemetry_raw GROUP BY signal_name ORDER BY 2 DESC;
```

Or run the bundled verification script against any TimescaleDB:

```bash
psql "$TS_DSN" -f db/scripts/verify_setup.sql
```

A quick end-to-end smoke test with a raw MQTT publish (requires `mosquitto_pub`):

```bash
mosquitto_pub -h localhost -t telemetry/eco_archers/events -m \
  '{"session_uid":"00000000-0000-0000-0000-000000000001","lap_number":1,
    "ts_wall_utc":"2026-08-01T00:00:00.000Z","ts_session_ms":0,
    "seq_in_session_start":1,"seq_in_session_end":1,
    "Speed_Kmh":25.0,"Voltage_780":40.0}'
# then: SELECT * FROM telemetry_raw ORDER BY time DESC LIMIT 2;
```

---

## 9. Exporting Logs to CSV

### Host-side (dev machine)

We provide scripts to connect to the database and export all tables to CSV
files in a local folder (`./csv_exports/`). These scripts run the export
*inside the running Docker container*, meaning you do **not** need local
database utilities (like `psql`) installed on your host.

- **On Windows (PowerShell)**:
  ```powershell
  .\db\scripts\export_to_csv.ps1
  ```
- **On Linux/macOS (Bash)**:
  ```bash
  ./db/scripts/export_to_csv.sh
  ```

### Server-side (saved on the backend itself)

The backend also keeps its own exports, written **inside the server**, so
they survive without a host connection. Each run writes timestamped files
(`sessions_<stamp>.csv`, `laps_<stamp>.csv`, `telemetry_raw_<stamp>.csv`),
preserving history across runs.

- **Single container**: run the built-in script, then browse/download the
  files at `http://<backend-host>:8080/` (read-only HTTP file server on the
  `csv-server` service, port 8080):
  ```bash
  docker exec ect-backend export_to_csv.sh
  # files in the persistent volume /var/lib/ect-backend/exports
  # (download via http://localhost:8080/)
  ```
- **Compose stack**: run the same script inside the database container; files
  land in the host `./csv_exports/` folder via a bind mount:
  ```bash
  docker exec ect-timescaledb sh /ops/backend/export_to_csv.sh
  ```

**Custom exports** (any query you like, straight to a file on the server):

```bash
# single container (output lands in /var/lib/ect-backend/exports/<file>.csv)
docker exec ect-backend psql -U postgres -d telemetry \
  -c "\copy (SELECT * FROM telemetry_raw WHERE signal_name = 'Speed_Kmh' AND time > now() - interval '1 day') TO '/var/lib/ect-backend/exports/speed_1d.csv' WITH CSV HEADER"

# compose stack (writes into ./csv_exports/)
docker exec ect-timescaledb psql -U postgres -d telemetry \
  -c "\copy (SELECT * FROM sessions) TO '/exports/sessions.csv' WITH CSV HEADER"
```

The `csv-server` HTTP endpoint is read-only (it serves files that
`export_to_csv.sh` or `psql \copy` already wrote — it never executes SQL).
Like the MQTT broker, it has no auth and is meant for trusted networks;
see [Production hardening](#production-hardening).

---

## 10. Grafana Custom Queries & Performance

When writing queries in Grafana, follow these rules to maintain database
performance and prevent dashboard latency.

### Rule 1: Always Constrain Queries on the Partition Key (`time`)

Because `telemetry_raw` is a hypertable partitioned by time, PostgreSQL must
scan every historical chunk if you do not filter by time.

**Bad Query (Scans all historical chunks):**
```sql
SELECT time_bucket('$__interval', time) AS "time", avg(value)::double precision AS value
FROM telemetry_raw
WHERE session_uid::text = '${session_id}'
  AND signal_name = 'Speed_Kmh'
GROUP BY 1
ORDER BY 1;
```

**Good Query (Restricts scans to chunks since the session started):**
```sql
SELECT time_bucket('$__interval', time) AS "time", avg(value)::double precision AS value
FROM telemetry_raw
WHERE session_uid::text = '${session_id}'
  AND signal_name = 'Speed_Kmh'
  AND time >= COALESCE((SELECT created_at FROM sessions WHERE uid::text = '${session_id}'), now() - interval '6 hours')
GROUP BY 1
ORDER BY 1;
```

### Rule 2: Use Dynamic Downsampling (`time_bucket`)

To prevent Grafana from pulling hundreds of thousands of raw data points
(which freezes the browser and strains the database), use TimescaleDB's
`time_bucket` along with Grafana's `$__interval` macro to aggregate data
points dynamically based on your zoom level:

```sql
SELECT
  time_bucket('$__interval', time) AS "time",
  avg(value)::double precision AS value
FROM telemetry_raw
WHERE session_uid::text = '${session_id}'
  AND signal_name = 'Speed_Kmh'
  AND time >= COALESCE((SELECT created_at FROM sessions WHERE uid::text = '${session_id}'), now() - interval '6 hours')
GROUP BY 1
ORDER BY 1;
```

### Rule 3: Normalizing Laps for Overlays

To overlay multiple laps on top of each other (starting at `0` on the
x-axis), calculate the relative duration offset using window functions and
cast it back to a timestamp so Grafana can render it on a timeline axis:

```sql
SELECT
  to_timestamp((ts_session_ms::bigint - MIN(ts_session_ms::bigint) OVER (PARTITION BY lap_number)) / 1000.0) AS "time",
  ('Lap ' || lap_number::text) AS metric,
  value::double precision AS value
FROM telemetry_raw
WHERE session_uid::text = '${session_id}'
  AND signal_name = 'Speed_Kmh'
  AND lap_number IS NOT NULL
  AND time >= COALESCE((SELECT created_at FROM sessions WHERE uid::text = '${session_id}'), now() - interval '6 hours')
ORDER BY lap_number::int, ts_session_ms::bigint;
```

> Segment keys (`lap_number`, `ts_session_ms`, `seq_*`) are stored as TEXT
> (see [Section 7](#7-database-schema-overview)), so always cast them for
> arithmetic or ordering: `lap_number::int`, `ts_session_ms::bigint`.

---

## 11. Troubleshooting

| Symptom                                     | Likely cause / fix                                                        |
| ------------------------------------------- | ------------------------------------------------------------------------- |
| App shows **Q (pending) growing**           | Broker unreachable. Check `docker logs ect-backend`; verify app MQTT host/port; the app spools and replays automatically when the broker returns. |
| Telegraf keeps restarting                   | Bad env interpolation — confirm `MQTT_HOST`, `TS_HOST`, `TOPIC_EVENTS` are set (`docker exec ect-backend env`). |
| No rows in `telemetry_raw`                  | Topics mismatch: broker topic vs `TOPIC_EVENTS` vs app publish topic must all agree. |
| Telegraf log: `08P01: insufficient data left in message` / `22P03: incorrect binary data format` on `COPY telemetry_raw` | Tag columns were typed `uuid`/`int`/`bigint` in an older schema. Telegraf's `outputs.postgresql` (≥1.31) COPYs in **binary** format and encodes tags as strings — columns must be TEXT. `ALTER TABLE telemetry_raw ALTER COLUMN <col> TYPE text;` (see [Section 7](#7-database-schema-overview)). |
| Sessions messages don't reach the `sessions` table | `uid` in `sessions_ingest_view` must be TEXT (cast to `uuid` in the trigger). Also ensure `vehicle_setup` is NOT in `included_keys` — a nested object makes `json_v2` emit zero metrics. |
| Grafana shows datasource error              | `TS_DATASOURCE_URL/PASSWORD` wrong for the deployment type (single: `localhost:5432`, Compose: `timescaledb:5432`). |
| Grafana loads no dashboards / no datasource | Grafana ≥13 defaults the provisioning path to `/usr/share/grafana/conf/provisioning` — the single container sets `GF_PATHS_PROVISIONING=/etc/grafana/provisioning-ect`. Also: provisioning env vars use Go `os.ExpandEnv` semantics — plain `${VAR}` only, the `:-default` syntax expands to an **empty string** (silently broken datasource). |
| Schema not applied on an existing container | `/docker-entrypoint-initdb.d` runs only on an **empty** data volume — wipe it (`docker compose down -v` or `docker volume rm`). |
| MQTT refused on non-local host              | Broker binds `0.0.0.0` — check host firewall/security group on port 1883. |

### Production hardening

`ops/backend` and `ops/local-stack` ship with **anonymous, plaintext** broker
access for local development. Before anything leaves a trusted network, follow
[ops/mosquitto/README.md](ops/mosquitto/README.md): create users, ACLs, and
TLS listener, set `allow_anonymous false`, and change every default password.
