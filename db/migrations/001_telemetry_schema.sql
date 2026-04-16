-- 001_telemetry_schema.sql
-- Baseline TimescaleDB schema for session/lap telemetry analytics.

CREATE EXTENSION IF NOT EXISTS timescaledb;
CREATE SCHEMA IF NOT EXISTS telemetry;

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
  detection_method TEXT NOT NULL,
  detection_confidence REAL,
  crossing_lat DOUBLE PRECISION,
  crossing_lon DOUBLE PRECISION,
  crossing_heading_deg REAL,
  created_at_utc TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK (
    lap_phase IS NULL OR
    lap_phase IN (
      'PRESTART_CHECK',
      'RUNNING',
      'CROSSING_CANDIDATE',
      'CROSSING_DEADZONE',
      'RESTART_ALLOWED',
      'LAP_COMPLETE',
      'SESSION_COMPLETE'
    )
  ),
  PRIMARY KEY (session_id, lap_number),
  FOREIGN KEY (session_id) REFERENCES telemetry.sessions(session_id)
);

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
  source TEXT NOT NULL,
  can_id INTEGER,
  seq_in_session BIGINT NOT NULL,
  quality_flag TEXT,
  tags JSONB,
  created_at_utc TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK (session_state IS NULL OR session_state IN ('IDLE', 'ARMED', 'LOGGING', 'ENDED')),
  CHECK (
    lap_phase IS NULL OR
    lap_phase IN (
      'PRESTART_CHECK',
      'RUNNING',
      'CROSSING_CANDIDATE',
      'CROSSING_DEADZONE',
      'RESTART_ALLOWED',
      'LAP_COMPLETE',
      'SESSION_COMPLETE'
    )
  ),
  FOREIGN KEY (session_id) REFERENCES telemetry.sessions(session_id)
);

SELECT create_hypertable(
  'telemetry.telemetry_events',
  'ts_wall_utc',
  if_not_exists => TRUE
);

CREATE TABLE IF NOT EXISTS telemetry.lap_events (
  ts_wall_utc TIMESTAMPTZ NOT NULL,
  session_id UUID NOT NULL,
  event_type TEXT NOT NULL,
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
  'ts_wall_utc',
  if_not_exists => TRUE
);

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
  'ts_wall_utc',
  if_not_exists => TRUE
);
