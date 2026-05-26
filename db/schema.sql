-- schema.sql
-- Consolidated TimescaleDB schema for session/lap telemetry analytics.

CREATE EXTENSION IF NOT EXISTS timescaledb;
CREATE SCHEMA IF NOT EXISTS telemetry;

-- 1. Core Tables

CREATE TABLE IF NOT EXISTS telemetry.sessions (
  session_id UUID PRIMARY KEY,
  session_name TEXT NOT NULL,
  session_state TEXT NOT NULL DEFAULT 'IDLE',
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
  CHECK (session_state IN ('IDLE', 'ARMED', 'LOGGING', 'ENDED'))
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

-- 2. Timescale Hypertables

SELECT create_hypertable(
  'telemetry.telemetry_events',
  'ts_wall_utc',
  if_not_exists => TRUE
);

SELECT create_hypertable(
  'telemetry.lap_events',
  'ts_wall_utc',
  if_not_exists => TRUE
);

SELECT create_hypertable(
  'telemetry.raw_can_frames',
  'ts_wall_utc',
  if_not_exists => TRUE
);

-- 3. Writable Ingestion View & Trigger

CREATE OR REPLACE VIEW telemetry.sessions_ingest_view AS
SELECT
  session_id,
  session_name,
  session_state,
  laps_completed,
  crossing_deadzone_ms
FROM telemetry.sessions;

CREATE OR REPLACE FUNCTION telemetry.upsert_session_ingest()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO telemetry.sessions (
    session_id,
    session_name,
    session_state,
    laps_completed,
    crossing_deadzone_ms
  )
  VALUES (
    NEW.session_id,
    COALESCE(NEW.session_name, 'UNKNOWN_SESSION'),
    COALESCE(NEW.session_state, 'IDLE'),
    COALESCE(NEW.laps_completed, 0),
    COALESCE(NEW.crossing_deadzone_ms, 3000)
  )
  ON CONFLICT (session_id)
  DO UPDATE SET
    session_name = COALESCE(EXCLUDED.session_name, sessions.session_name),
    session_state = COALESCE(EXCLUDED.session_state, sessions.session_state),
    laps_completed = COALESCE(EXCLUDED.laps_completed, sessions.laps_completed),
    crossing_deadzone_ms = COALESCE(EXCLUDED.crossing_deadzone_ms, sessions.crossing_deadzone_ms);
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trigger_upsert_session_ingest ON telemetry.sessions_ingest_view;
CREATE TRIGGER trigger_upsert_session_ingest
INSTEAD OF INSERT ON telemetry.sessions_ingest_view
FOR EACH ROW
EXECUTE FUNCTION telemetry.upsert_session_ingest();

-- 4. Indexes

CREATE INDEX IF NOT EXISTS idx_events_session_lap_time
  ON telemetry.telemetry_events (session_id, lap_number, ts_session_ms);

CREATE INDEX IF NOT EXISTS idx_events_session_metric_time
  ON telemetry.telemetry_events (session_id, metric_key, ts_wall_utc DESC);

CREATE INDEX IF NOT EXISTS idx_events_metric_time
  ON telemetry.telemetry_events (metric_key, ts_wall_utc DESC);

CREATE UNIQUE INDEX IF NOT EXISTS uq_events_dedupe
  ON telemetry.telemetry_events (session_id, seq_in_session, ts_wall_utc);

CREATE INDEX IF NOT EXISTS idx_lap_events_session_time
  ON telemetry.lap_events (session_id, ts_wall_utc DESC);

CREATE INDEX IF NOT EXISTS idx_sessions_state_time
  ON telemetry.sessions (session_state, started_at_utc DESC);

CREATE INDEX IF NOT EXISTS idx_laps_crossing_quality
  ON telemetry.laps (session_id, lap_number, crossing_valid, deadzone_ms);

CREATE INDEX IF NOT EXISTS idx_raw_frames_session_time
  ON telemetry.raw_can_frames (session_id, ts_wall_utc DESC);

CREATE INDEX IF NOT EXISTS idx_events_session_time_desc
  ON telemetry.telemetry_events (session_id, ts_wall_utc DESC);

CREATE INDEX IF NOT EXISTS idx_events_session_metric_session_ms
  ON telemetry.telemetry_events (session_id, metric_key, ts_session_ms);

CREATE INDEX IF NOT EXISTS idx_events_session_created_desc
  ON telemetry.telemetry_events (session_id, created_at_utc DESC);

CREATE INDEX IF NOT EXISTS idx_sessions_created_desc
  ON telemetry.sessions (created_at_utc DESC);

-- 5. Compression Policies (Infinite Retention, per 'dont discard' command)

ALTER TABLE telemetry.telemetry_events
  SET (
    timescaledb.compress = true,
    timescaledb.compress_segmentby = 'session_id,metric_key'
  );

ALTER TABLE telemetry.raw_can_frames
  SET (
    timescaledb.compress = true,
    timescaledb.compress_segmentby = 'session_id,can_id'
  );

ALTER TABLE telemetry.lap_events
  SET (
    timescaledb.compress = true,
    timescaledb.compress_segmentby = 'session_id,event_type'
  );

DO $$
BEGIN
  PERFORM add_compression_policy('telemetry.telemetry_events', INTERVAL '3 days');
EXCEPTION
  WHEN duplicate_object THEN NULL;
  WHEN undefined_function THEN
    RAISE NOTICE 'Timescale policy function unavailable: add_compression_policy';
END $$;

DO $$
BEGIN
  PERFORM add_compression_policy('telemetry.raw_can_frames', INTERVAL '1 days');
EXCEPTION
  WHEN duplicate_object THEN NULL;
  WHEN undefined_function THEN
    RAISE NOTICE 'Timescale policy function unavailable: add_compression_policy';
END $$;

DO $$
BEGIN
  PERFORM add_compression_policy('telemetry.lap_events', INTERVAL '7 days');
EXCEPTION
  WHEN duplicate_object THEN NULL;
  WHEN undefined_function THEN
    RAISE NOTICE 'Timescale policy function unavailable: add_compression_policy';
END $$;

-- 6. Analytical Summary Views

CREATE OR REPLACE VIEW telemetry.session_summary_v1 AS
SELECT
  s.session_id,
  s.session_name,
  s.session_state,
  s.laps_completed,
  s.started_at_utc,
  s.ended_at_utc,
  COALESCE(e.event_count, 0) AS event_count,
  e.first_event_at_utc,
  e.last_event_at_utc,
  e.distinct_metric_keys,
  e.max_seq_in_session,
  e.first_ts_session_ms,
  e.last_ts_session_ms,
  e.avg_metric_value,
  COALESCE(lap.total_laps, 0) AS total_laps,
  COALESCE(lap.valid_laps, 0) AS valid_laps,
  COALESCE(lap.invalid_laps, 0) AS invalid_laps,
  lap.best_lap_ms,
  lap.worst_lap_ms,
  lap.avg_lap_ms,
  s.created_at_utc
FROM telemetry.sessions s
LEFT JOIN (
  SELECT
    session_id,
    COUNT(*)::BIGINT AS event_count,
    MIN(ts_wall_utc) AS first_event_at_utc,
    MAX(ts_wall_utc) AS last_event_at_utc,
    COUNT(DISTINCT metric_key)::INTEGER AS distinct_metric_keys,
    MAX(seq_in_session) AS max_seq_in_session,
    MIN(ts_session_ms) AS first_ts_session_ms,
    MAX(ts_session_ms) AS last_ts_session_ms,
    AVG(metric_value) AS avg_metric_value
  FROM telemetry.telemetry_events
  GROUP BY session_id
) e
  ON e.session_id = s.session_id
LEFT JOIN (
  SELECT
    session_id,
    COUNT(*)::INTEGER AS total_laps,
    COUNT(*) FILTER (WHERE crossing_valid)::INTEGER AS valid_laps,
    COUNT(*) FILTER (WHERE NOT crossing_valid)::INTEGER AS invalid_laps,
    MIN(duration_ms) FILTER (WHERE duration_ms IS NOT NULL) AS best_lap_ms,
    MAX(duration_ms) FILTER (WHERE duration_ms IS NOT NULL) AS worst_lap_ms,
    AVG(duration_ms) FILTER (WHERE duration_ms IS NOT NULL) AS avg_lap_ms
  FROM telemetry.laps
  GROUP BY session_id
) lap
  ON lap.session_id = s.session_id;

CREATE OR REPLACE VIEW telemetry.lap_summary_v1 AS
SELECT
  l.session_id,
  l.lap_number,
  l.started_at_utc,
  l.ended_at_utc,
  l.duration_ms,
  l.crossing_valid,
  l.deadzone_ms,
  l.detection_method,
  l.detection_confidence,
  stats.event_count,
  stats.min_speed_kmh,
  stats.max_speed_kmh,
  stats.avg_speed_kmh,
  stats.min_power_w,
  stats.max_power_w,
  stats.avg_power_w,
  stats.first_ts_session_ms,
  stats.last_ts_session_ms
FROM telemetry.laps l
LEFT JOIN (
  SELECT
    session_id,
    lap_number,
    COUNT(*)::BIGINT AS event_count,
    MIN(metric_value) FILTER (WHERE metric_key = 'Speed_Kmh') AS min_speed_kmh,
    MAX(metric_value) FILTER (WHERE metric_key = 'Speed_Kmh') AS max_speed_kmh,
    AVG(metric_value) FILTER (WHERE metric_key = 'Speed_Kmh') AS avg_speed_kmh,
    MIN(metric_value) FILTER (WHERE metric_key = 'Power_W') AS min_power_w,
    MAX(metric_value) FILTER (WHERE metric_key = 'Power_W') AS max_power_w,
    AVG(metric_value) FILTER (WHERE metric_key = 'Power_W') AS avg_power_w,
    MIN(ts_session_ms) AS first_ts_session_ms,
    MAX(ts_session_ms) AS last_ts_session_ms
  FROM telemetry.telemetry_events
  WHERE lap_number IS NOT NULL
  GROUP BY session_id, lap_number
) stats
  ON stats.session_id = l.session_id
 AND stats.lap_number = l.lap_number;

CREATE OR REPLACE VIEW telemetry.latest_metric_values_v1 AS
SELECT DISTINCT ON (e.session_id, e.metric_key)
  e.session_id,
  e.metric_key,
  e.metric_value,
  e.unit,
  e.source,
  e.lap_number,
  e.session_state,
  e.lap_phase,
  e.ts_wall_utc,
  e.ts_session_ms,
  e.seq_in_session,
  e.quality_flag,
  e.created_at_utc
FROM telemetry.telemetry_events e
ORDER BY e.session_id, e.metric_key, e.ts_wall_utc DESC, e.seq_in_session DESC;

-- 7. Audit and Recovery Logging

CREATE TABLE IF NOT EXISTS telemetry.tx_command_audit (
  ts_wall_utc TIMESTAMPTZ NOT NULL,
  session_id UUID,
  command_sequence INTEGER,
  command_key TEXT NOT NULL,
  args_json JSONB,
  target_can_id INTEGER,
  status TEXT NOT NULL,
  retries INTEGER NOT NULL DEFAULT 0,
  reason TEXT,
  source TEXT,
  created_at_utc TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK (status IN ('acked', 'nacked', 'timeout', 'rejected')),
  FOREIGN KEY (session_id) REFERENCES telemetry.sessions(session_id)
);

SELECT create_hypertable(
  'telemetry.tx_command_audit',
  'ts_wall_utc',
  if_not_exists => TRUE
);

CREATE TABLE IF NOT EXISTS telemetry.recovery_events (
  ts_wall_utc TIMESTAMPTZ NOT NULL,
  session_id UUID NOT NULL,
  checkpoint_seq_in_session BIGINT,
  spool_max_seq_in_session BIGINT,
  recovered_seq_in_session BIGINT NOT NULL,
  replay_backlog_count INTEGER,
  recovery_resume_count INTEGER,
  details JSONB,
  created_at_utc TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK (recovered_seq_in_session >= 0),
  FOREIGN KEY (session_id) REFERENCES telemetry.sessions(session_id)
);

SELECT create_hypertable(
  'telemetry.recovery_events',
  'ts_wall_utc',
  if_not_exists => TRUE
);

CREATE INDEX IF NOT EXISTS idx_tx_command_audit_session_time
  ON telemetry.tx_command_audit (session_id, ts_wall_utc DESC);

CREATE INDEX IF NOT EXISTS idx_tx_command_audit_status_time
  ON telemetry.tx_command_audit (status, ts_wall_utc DESC);

CREATE INDEX IF NOT EXISTS idx_recovery_events_session_time
  ON telemetry.recovery_events (session_id, ts_wall_utc DESC);

ALTER TABLE telemetry.tx_command_audit
  SET (
    timescaledb.compress = true,
    timescaledb.compress_segmentby = 'session_id,status,command_key'
  );

ALTER TABLE telemetry.recovery_events
  SET (
    timescaledb.compress = true,
    timescaledb.compress_segmentby = 'session_id'
  );

DO $$
BEGIN
  PERFORM add_compression_policy('telemetry.tx_command_audit', INTERVAL '7 days');
EXCEPTION
  WHEN duplicate_object THEN NULL;
  WHEN undefined_function THEN
    RAISE NOTICE 'Timescale policy function unavailable: add_compression_policy';
END $$;

DO $$
BEGIN
  PERFORM add_compression_policy('telemetry.recovery_events', INTERVAL '7 days');
EXCEPTION
  WHEN duplicate_object THEN NULL;
  WHEN undefined_function THEN
    RAISE NOTICE 'Timescale policy function unavailable: add_compression_policy';
END $$;

