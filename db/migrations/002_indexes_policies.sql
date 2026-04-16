-- 002_indexes_policies.sql
-- Indexes, dedupe guarantees, compression, and retention policies.

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

CREATE INDEX IF NOT EXISTS idx_raw_frames_session_time
  ON telemetry.raw_can_frames (session_id, ts_wall_utc DESC);

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
  PERFORM add_retention_policy('telemetry.telemetry_events', INTERVAL '365 days');
EXCEPTION
  WHEN duplicate_object THEN NULL;
  WHEN undefined_function THEN
    RAISE NOTICE 'Timescale policy function unavailable: add_retention_policy';
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
  PERFORM add_retention_policy('telemetry.raw_can_frames', INTERVAL '30 days');
EXCEPTION
  WHEN duplicate_object THEN NULL;
  WHEN undefined_function THEN
    RAISE NOTICE 'Timescale policy function unavailable: add_retention_policy';
END $$;

DO $$
BEGIN
  PERFORM add_compression_policy('telemetry.lap_events', INTERVAL '7 days');
EXCEPTION
  WHEN duplicate_object THEN NULL;
  WHEN undefined_function THEN
    RAISE NOTICE 'Timescale policy function unavailable: add_compression_policy';
END $$;

DO $$
BEGIN
  PERFORM add_retention_policy('telemetry.lap_events', INTERVAL '365 days');
EXCEPTION
  WHEN duplicate_object THEN NULL;
  WHEN undefined_function THEN
    RAISE NOTICE 'Timescale policy function unavailable: add_retention_policy';
END $$;
