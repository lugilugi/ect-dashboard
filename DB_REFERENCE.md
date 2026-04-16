# ECT Dashboard Database Reference

This document defines a practical database structure for the telemetry pipeline:

1. In-cabin app publishes telemetry events to Mosquitto.
2. Telegraf subscribes and writes to TimescaleDB.
3. Grafana reads TimescaleDB for dashboards and lap analysis.

This schema is designed for:

1. Session-first filtering.
2. Lap-by-lap drilldown within a session.
3. Dual timestamps (wall time and session-relative time).
4. Geofenced lap indicators and confidence tracking.
5. Lap counting from valid crossings with filter and deadzone controls.

## 1. Stack and Data Flow

1. Tailscale: transport/private network between car and pitwall endpoints.
2. Mosquitto: MQTT broker that receives batched telemetry events.
3. Telegraf: backend-side MQTT consumer and TimescaleDB writer (does not run in the in-cabin app).
4. TimescaleDB: canonical telemetry store.
5. Grafana: visualization and analysis.

Flow:

1. App publishes JSON batches to MQTT topic, for example telemetry/eco_archers/events.
2. Telegraf parses each event and writes rows to telemetry_events.
3. Session/lap metadata is written by backend-side ingest logic using session/lap lifecycle events from the app.
4. Grafana queries by selected session_id, then lap_number.

## 2. Core Concepts

### Session
A continuous run with one unique session_id.

### Lap
A segment inside a session, assigned by geofence crossing logic with filter and deadzone controls.

### Event
A single metric value sample with two timestamps:

1. ts_wall_utc: absolute UTC time.
2. ts_session_ms: elapsed time from session start in milliseconds.

### Shared Canonical Runtime Values
These values must match UI.md and REBUILD_PLAN.md.

1. ui_mode: DRIVER, SERVICE.
2. session_state: IDLE, ARMED, LOGGING, ENDED.

## 3. Recommended Schema

Use a dedicated schema:

```sql
CREATE SCHEMA IF NOT EXISTS telemetry;
```

### 3.1 sessions

```sql
CREATE TABLE IF NOT EXISTS telemetry.sessions (
  session_id UUID PRIMARY KEY,
  session_name TEXT NOT NULL,
  session_state TEXT NOT NULL DEFAULT 'IDLE',
  ui_mode TEXT NOT NULL DEFAULT 'DRIVER',
  laps_planned INTEGER NOT NULL DEFAULT 1,
  laps_completed INTEGER NOT NULL DEFAULT 0,
  crossing_speed_threshold_kmh DOUBLE PRECISION NOT NULL DEFAULT 0.5,
  crossing_deadzone_ms INTEGER NOT NULL DEFAULT 3000,
  crossing_heading_tolerance_deg DOUBLE PRECISION NOT NULL DEFAULT 45.0,
  vehicle_id TEXT,
  driver_id TEXT,
  armed_at_utc TIMESTAMPTZ,
  started_at_utc TIMESTAMPTZ,
  ended_at_utc TIMESTAMPTZ,
  ended_reason TEXT,
  start_lat DOUBLE PRECISION,
  start_lon DOUBLE PRECISION,
  notes TEXT,
  config JSONB,
  created_at_utc TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK (session_state IN ('IDLE', 'ARMED', 'LOGGING', 'ENDED')),
  CHECK (ui_mode IN ('DRIVER', 'SERVICE'))
);
```

### 3.2 laps

```sql
CREATE TABLE IF NOT EXISTS telemetry.laps (
  session_id UUID NOT NULL,
  lap_number INTEGER NOT NULL,
  started_at_utc TIMESTAMPTZ NOT NULL,
  ended_at_utc TIMESTAMPTZ,
  duration_ms BIGINT,
  lap_phase TEXT,
  crossing_detected BOOLEAN NOT NULL DEFAULT FALSE,
  crossing_valid BOOLEAN NOT NULL DEFAULT FALSE,
  deadzone_applied BOOLEAN NOT NULL DEFAULT FALSE,
  deadzone_ms BIGINT,
  crossing_speed_kmh DOUBLE PRECISION,
  detection_method TEXT NOT NULL,   -- geofence, manual, fallback
  detection_confidence REAL,         -- 0.0 to 1.0
  crossing_lat DOUBLE PRECISION,
  crossing_lon DOUBLE PRECISION,
  crossing_heading_deg REAL,
  created_at_utc TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK (lap_phase IS NULL OR lap_phase IN ('PRESTART_CHECK', 'RUNNING', 'CROSSING_CANDIDATE', 'CROSSING_DEADZONE', 'RESTART_ALLOWED', 'LAP_COMPLETE', 'SESSION_COMPLETE')),
  PRIMARY KEY (session_id, lap_number),
  FOREIGN KEY (session_id) REFERENCES telemetry.sessions(session_id)
);
```

### 3.3 telemetry_events (Hypertable)

```sql
CREATE TABLE IF NOT EXISTS telemetry.telemetry_events (
  ts_wall_utc TIMESTAMPTZ NOT NULL,
  session_id UUID NOT NULL,
  lap_number INTEGER,
  ts_session_ms BIGINT NOT NULL,
  session_state TEXT,
  lap_phase TEXT,
  metric_key TEXT NOT NULL,
  metric_value DOUBLE PRECISION NOT NULL,
  unit TEXT,
  source TEXT NOT NULL,             -- can, derived, phone_gps, external_gps
  can_id INTEGER,
  seq_in_session BIGINT NOT NULL,
  quality_flag TEXT,                -- ok, stale, estimated, invalid
  tags JSONB,
  created_at_utc TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK (session_state IS NULL OR session_state IN ('IDLE', 'ARMED', 'LOGGING', 'ENDED')),
  CHECK (lap_phase IS NULL OR lap_phase IN ('PRESTART_CHECK', 'RUNNING', 'CROSSING_CANDIDATE', 'CROSSING_DEADZONE', 'RESTART_ALLOWED', 'LAP_COMPLETE', 'SESSION_COMPLETE')),
  FOREIGN KEY (session_id) REFERENCES telemetry.sessions(session_id)
);

SELECT create_hypertable(
  'telemetry.telemetry_events',
  by_range('ts_wall_utc'),
  if_not_exists => TRUE
);
```

### 3.4 lap_events (optional but recommended)

```sql
CREATE TABLE IF NOT EXISTS telemetry.lap_events (
  ts_wall_utc TIMESTAMPTZ NOT NULL,
  session_id UUID NOT NULL,
  event_type TEXT NOT NULL,         -- crossing_detected, rejected, corrected
  lap_number INTEGER,
  reason TEXT,
  method TEXT,
  confidence REAL,
  lat DOUBLE PRECISION,
  lon DOUBLE PRECISION,
  heading_deg REAL,
  speed_kmh REAL,
  details JSONB,
  created_at_utc TIMESTAMPTZ NOT NULL DEFAULT now(),
  FOREIGN KEY (session_id) REFERENCES telemetry.sessions(session_id)
);

SELECT create_hypertable(
  'telemetry.lap_events',
  by_range('ts_wall_utc'),
  if_not_exists => TRUE
);
```

### 3.5 raw_can_frames (optional for replay)

```sql
CREATE TABLE IF NOT EXISTS telemetry.raw_can_frames (
  ts_wall_utc TIMESTAMPTZ NOT NULL,
  session_id UUID NOT NULL,
  ts_session_ms BIGINT NOT NULL,
  can_id INTEGER NOT NULL,
  payload_hex TEXT NOT NULL,
  bus_name TEXT,
  seq_in_session BIGINT,
  source TEXT NOT NULL,
  created_at_utc TIMESTAMPTZ NOT NULL DEFAULT now(),
  FOREIGN KEY (session_id) REFERENCES telemetry.sessions(session_id)
);

SELECT create_hypertable(
  'telemetry.raw_can_frames',
  by_range('ts_wall_utc'),
  if_not_exists => TRUE
);
```

## 4. Indexing Strategy

```sql
CREATE INDEX IF NOT EXISTS idx_events_session_lap_time
  ON telemetry.telemetry_events (session_id, lap_number, ts_session_ms);

CREATE INDEX IF NOT EXISTS idx_events_session_metric_time
  ON telemetry.telemetry_events (session_id, metric_key, ts_wall_utc DESC);

CREATE INDEX IF NOT EXISTS idx_events_metric_time
  ON telemetry.telemetry_events (metric_key, ts_wall_utc DESC);

CREATE UNIQUE INDEX IF NOT EXISTS uq_events_dedupe
  ON telemetry.telemetry_events (session_id, seq_in_session);

CREATE INDEX IF NOT EXISTS idx_lap_events_session_time
  ON telemetry.lap_events (session_id, ts_wall_utc DESC);

CREATE INDEX IF NOT EXISTS idx_sessions_state_time
  ON telemetry.sessions (session_state, started_at_utc DESC);

CREATE INDEX IF NOT EXISTS idx_laps_crossing_quality
  ON telemetry.laps (session_id, lap_number, crossing_valid, deadzone_ms);
```

## 5. Compression and Retention

Use Timescale compression and retention for long-running telemetry.

```sql
ALTER TABLE telemetry.telemetry_events
  SET (timescaledb.compress = true, timescaledb.compress_segmentby = 'session_id,metric_key');

SELECT add_compression_policy('telemetry.telemetry_events', INTERVAL '3 days');
SELECT add_retention_policy('telemetry.telemetry_events', INTERVAL '365 days');

ALTER TABLE telemetry.raw_can_frames
  SET (timescaledb.compress = true, timescaledb.compress_segmentby = 'session_id,can_id');

SELECT add_compression_policy('telemetry.raw_can_frames', INTERVAL '1 days');
SELECT add_retention_policy('telemetry.raw_can_frames', INTERVAL '30 days');
```

## 6. Session/Lap Query Patterns

### 6.1 List latest sessions

```sql
SELECT session_id, session_name, started_at_utc, ended_at_utc
FROM telemetry.sessions
ORDER BY COALESCE(started_at_utc, armed_at_utc, created_at_utc) DESC
LIMIT 50;
```

### 6.2 List laps in one session

```sql
SELECT lap_number,
       started_at_utc,
       ended_at_utc,
       duration_ms,
      crossing_detected,
      crossing_valid,
      deadzone_applied,
      deadzone_ms,
       detection_method,
       detection_confidence
FROM telemetry.laps
WHERE session_id = $1
ORDER BY lap_number;
```

### 6.3 Pull one metric by session and lap

```sql
SELECT ts_wall_utc, ts_session_ms, metric_value
FROM telemetry.telemetry_events
WHERE session_id = $1
  AND lap_number = $2
  AND metric_key = 'Speed_Kmh'
ORDER BY ts_session_ms;
```

### 6.4 Compare the same metric across laps (normalized lap axis)

```sql
SELECT lap_number,
       ts_session_ms - MIN(ts_session_ms) OVER (PARTITION BY lap_number) AS lap_elapsed_ms,
       metric_value
FROM telemetry.telemetry_events
WHERE session_id = $1
  AND metric_key = 'Speed_Kmh'
ORDER BY lap_number, lap_elapsed_ms;
```

### 6.5 Find invalid crossings in a session

```sql
SELECT lap_number,
       crossing_detected,
       crossing_valid,
       deadzone_applied,
       deadzone_ms,
       crossing_speed_kmh
FROM telemetry.laps
WHERE session_id = $1
  AND crossing_detected = TRUE
  AND crossing_valid = FALSE
ORDER BY lap_number;
```

## 7. Dual Timestamp Rules

Every telemetry event should include both:

1. ts_wall_utc for global time alignment across systems.
2. ts_session_ms for run-relative analysis and lap overlays.

Guidance:

1. Generate ts_wall_utc at ingest time in app (UTC ISO-8601).
2. Generate ts_session_ms from session start monotonic clock.
3. Never recompute ts_session_ms in DB from wall time.

## 8. Geofenced Lap Indicator Design

Recommended detection rules:

1. Define finish line as two coordinates (line segment A->B).
2. Detect crossing by line intersection between consecutive GPS points.
3. Validate heading window around expected travel direction.
4. Validate minimum speed at crossing.
5. Apply minimum lap time guard (example: 45 to 60 seconds).
6. Apply debounce/cooldown guard to prevent repeated crossing noise.
7. Write crossing result to lap_events with confidence.

Crossing validity rules:

1. Lap boundary crossing alone does not finalize lap.
2. Apply heading, speed, and sequence filters before accepting crossing.
3. Apply minimum lap time guard before accepting crossing.
4. Apply deadzone/debounce window after each accepted crossing.
5. Count lap only if crossing_valid is true.

Fallback behavior:

1. If external GPS stale and phone GPS active, allow lap detection but lower confidence.
2. Mark detection_method as fallback and persist confidence.
3. Allow post-run correction by engineer if confidence is low.

## 9. MQTT Event Payload Contract (Recommended)

Topic:

1. telemetry/eco_archers/events

Batch shape:

```json
{
  "schema_version": 1,
  "batch_id": "uuid",
  "session_id": "uuid",
  "session_state": "LOGGING",
  "created_at_utc": "2026-04-15T12:34:56.789Z",
  "laps_planned": 10,
  "laps_completed": 2,
  "events": [
    {
      "ts_wall_utc": "2026-04-15T12:34:56.700Z",
      "ts_session_ms": 123456,
      "lap_number": 3,
      "session_state": "LOGGING",
      "lap_phase": "CROSSING_DEADZONE",
      "metric_key": "Speed_Kmh",
      "metric_value": 35.2,
      "unit": "km/h",
      "source": "external_gps",
      "can_id": 1280,
      "seq_in_session": 99881
    }
  ]
}
```

## 9.1 UX-to-DB Write Flow
This maps the in-cabin UX flow to persistence behavior.

1. IDLE (boot):
- Insert or prepare session row with session_state=IDLE and ui_mode=DRIVER.

2. ARMED (session configured):
- Update telemetry.sessions.session_state to ARMED.
- Set armed_at_utc.
- Persist selected run metadata in config JSONB.

3. LOGGING (run active):
- Update telemetry.sessions.session_state to LOGGING.
- Set started_at_utc if not already set.
- Write telemetry_events continuously with both timestamps.
- Insert/update laps as geofence crossings are detected.
- Increment laps_completed only for valid filtered crossings.

4. ENDED (run complete):
- Update telemetry.sessions.session_state to ENDED.
- Set ended_at_utc and ended_reason.
- Finalize lap durations and confidence fields.
- Persist final crossing validity outcomes per lap.

5. SERVICE mode (post-run diagnostics):
- Update telemetry.sessions.ui_mode to SERVICE while keeping session_state=ENDED.

## 9.2 Replay Dedupe and Idempotency

Purpose:

1. Prevent duplicate rows when retries or outage replay resend the same event.

Rules:

1. Replay must keep original `ts_wall_utc`, `ts_session_ms`, and `seq_in_session`.
2. `seq_in_session` must be monotonic within a session and never reused for a different event.
3. Deduplication is enforced by `uq_events_dedupe` on `session_id` + `seq_in_session`.

## 10. Telegraf Mapping Notes

With telegraf mqtt_consumer + json_v2:

Telegraf role note:

1. Telegraf is backend-side only and is not embedded in the in-cabin app runtime.

1. Parse session_id, lap_number, metric_key as tags or dimensions.
2. Keep metric_value as field.
3. Keep ts_wall_utc as timestamp.
4. Write ts_session_ms as field (BIGINT).

Practical note:

1. High-cardinality tags hurt performance. Avoid tagging free-text fields.
2. session_id and metric_key are acceptable as query dimensions in this use case.

## 11. Grafana Setup Suggestions

Variables:

1. session_id variable from telemetry.sessions ordered by started_at_utc desc.
2. lap_number variable filtered by selected session_id.

Panels:

1. Session timeline panel by ts_wall_utc.
2. Lap overlay panel by ts_session_ms or lap_elapsed_ms.
3. Lap summary table: energy, average speed, duration, efficiency.
4. Lap confidence panel from telemetry.lap_events.

## 12. Migration Checklist

1. Create schema and tables.
2. Convert telemetry_events and lap_events to hypertables.
3. Add indexes.
4. Enable compression and retention.
5. Update app payload to include ts_wall_utc + ts_session_ms + lap_number.
6. Update Telegraf parser and write mapping.
7. Build Grafana variables and panels.
8. Validate session-first then lap-first query paths.

## 13. Validation Checklist

1. New session appears in telemetry.sessions at run start.
2. Lap rows are created as crossings occur.
3. telemetry_events rows carry both timestamps.
4. Queries by session_id and lap_number are performant.
5. Phone GPS fallback events are clearly marked by source.
6. Geofence false positives are logged and diagnosable in lap_events.
7. session_state transitions follow IDLE -> ARMED -> LOGGING -> ENDED.
8. ui_mode transitions are auditable (DRIVER to SERVICE after logging stops).
9. laps_completed never exceeds laps_planned.
10. Each counted lap has crossing_valid=true after filter and deadzone/debounce checks.
11. Session ENDED (normal) only occurs after final lap validation unless explicitly marked as abort.
