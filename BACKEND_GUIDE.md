# ECT Dashboard: Backend Setup & Query Guide

This guide describes how to run, manage, and query the unified ECT Dashboard backend stack.

---

## 1. System Architecture

The ECT Dashboard backend is a containerized stack designed for time-series telemetry collection and visualization:

```
[Flutter Mobile App] --(MQTT JSON Batches)--> [Mosquitto MQTT Broker]
                                                      |
                                             (Subscribed Feeds)
                                                      v
[TimescaleDB PostgreSQL] <-- (SQL Inserts) -- [Telegraf Collector]
           |
   (SQL Query Pulls)
           v
   [Grafana Dashboards]
```

### Stack Components:
1. **Mosquitto (MQTT Broker)**: Port `1883`. Receives batched JSON messages from the Flutter app.
2. **Telegraf (Ingestion Daemon)**: Subscribes to MQTT topics, parses JSON, and performs SQL insertions.
3. **TimescaleDB (PostgreSQL)**: Port `5432`. Tailored for fast time-series ingestion and chunk compression.
4. **Grafana (Visualization)**: Port `3000`. Renders dashboards and provides visual lap analysis.

---

## 2. Docker Quick Start

The entire stack is configured via a single Compose file.

### Prerequisites:
- Install **Docker** & **Docker Compose**.

### Spin Up the Backend:
Navigate to the `ops/local-stack` directory and run:
```bash
docker compose up --build -d
```
This builds the custom Telegraf parser, initializes the TimescaleDB database schema using `db/schema.sql`, and launches Grafana.

### Stop and Wipe Volumes (Fresh Start):
To wipe all historical database records and start with a clean volume:
```bash
docker compose down -v
```

---

## 3. Database Schema Overview

All database definitions are consolidated in [db/schema.sql](file:///c:/Users/luigi/OneDrive%20-%20De%20La%20Salle%20University%20-%20Manila/ECT/GitHub/ect-dashboard/db/schema.sql).

### Core Tables:
1. **`telemetry.sessions`**: Metadata for active runs (session ID, session name, state, location, notes).
2. **`telemetry.laps`**: Lap sequence numbers, durations, crossing location stats, and detection confidence.
3. **`telemetry.telemetry_events`** (Hypertable): High-frequency CAN bus metric values (voltage, current, speeds) with dual timestamps.
4. **`telemetry.lap_events`** (Hypertable): Audit trail logs detailing geofence detection crossings.
5. **`telemetry.raw_can_frames`** (Hypertable): Raw diagnostic CAN hex strings.
6. **`telemetry.tx_command_audit`** (Hypertable): History of commands sent to the vehicle and their ack status.
7. **`telemetry.recovery_events`** (Hypertable): Crash-recovery sequence and spool playback logs.

---

## 4. Exporting Logs to CSV

We provide scripts to connect to the database and export all tables to CSV files in a local folder (`./csv_exports/`). These scripts run the export *inside the running Docker container*, meaning you do **not** need local database utilities (like `psql`) installed on your host.

- **On Windows (PowerShell)**:
  ```powershell
  .\db\scripts\export_to_csv.ps1
  ```
- **On Linux/macOS (Bash)**:
  ```bash
  ./db/scripts/export_to_csv.sh
  ```

---

## 5. Grafana Custom Queries & Performance

When writing queries in Grafana, follow these rules to maintain database performance and prevent dashboard latency.

### Rule 1: Always Constrain Queries on Partition Key (`ts_wall_utc`)
Because `telemetry_events` is a hypertable partitioned by time (`ts_wall_utc`), PostgreSQL must scan every historical chunk if you do not filter by time. 

**Bad Query (Scans all historical chunks)**:
```sql
SELECT ts_wall_utc AS "time", metric_value AS value 
FROM telemetry.telemetry_events 
WHERE session_id::text = '${session_id}' 
  AND metric_key = 'Speed_Kmh' 
ORDER BY ts_wall_utc;
```

**Good Query (Restricts scans to chunks since the session started)**:
```sql
SELECT ts_wall_utc AS "time", metric_value AS value 
FROM telemetry.telemetry_events 
WHERE session_id::text = '${session_id}' 
  AND metric_key = 'Speed_Kmh' 
  AND ts_wall_utc >= COALESCE((SELECT created_at_utc FROM telemetry.sessions WHERE session_id::text = '${session_id}'), now() - interval '6 hours')
ORDER BY ts_wall_utc;
```

---

### Rule 2: Use Dynamic Downsampling (`time_bucket`)
To prevent Grafana from pulling hundreds of thousands of raw data points (which freezes the browser and strains the database), use TimescaleDB's `time_bucket` along with Grafana's `$__interval` macro to aggregate data points dynamically based on your zoom level:

```sql
SELECT 
  time_bucket('$__interval', ts_wall_utc) AS "time", 
  avg(metric_value)::double precision AS value 
FROM telemetry.telemetry_events 
WHERE session_id::text = '${session_id}' 
  AND metric_key = 'Speed_Kmh' 
  AND ts_wall_utc >= COALESCE((SELECT created_at_utc FROM telemetry.sessions WHERE session_id::text = '${session_id}'), now() - interval '6 hours')
GROUP BY 1 
ORDER BY 1;
```

---

### Rule 3: Normalizing Laps for Overlays
To overlay multiple laps on top of each other (starting at `0` on the x-axis), calculate the relative duration offset using window functions and cast it back to a timestamp so Grafana can render it on a timeline axis:

```sql
SELECT 
  to_timestamp((ts_session_ms - MIN(ts_session_ms) OVER (PARTITION BY lap_number)) / 1000.0) AS "time", 
  ('Lap ' || lap_number::text) AS metric, 
  metric_value::double precision AS value 
FROM telemetry.telemetry_events 
WHERE session_id::text = '${session_id}' 
  AND metric_key = 'Speed_Kmh' 
  AND lap_number IS NOT NULL 
  AND ts_wall_utc >= COALESCE((SELECT created_at_utc FROM telemetry.sessions WHERE session_id::text = '${session_id}'), now() - interval '6 hours')
ORDER BY lap_number, ts_session_ms;
```
