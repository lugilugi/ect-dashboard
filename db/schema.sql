-- Enable UUID generation extension if not active
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- 1. Metadata: Track configurations, environment, and run parameters
CREATE TABLE sessions (
    uid UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    session_name VARCHAR(100) NOT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    vehicle_setup JSONB                                -- "Something else" structured parameter block
);

-- 2. Metadata: Laps segment boundaries
CREATE TABLE laps (
    id SERIAL PRIMARY KEY,
    session_uid UUID REFERENCES sessions(uid) ON DELETE CASCADE,
    lap_number INT NOT NULL,
    started_at TIMESTAMPTZ NOT NULL,
    ended_at TIMESTAMPTZ,
    UNIQUE(session_uid, lap_number)
);

-- 3. Core Time-Series Sink Table
CREATE TABLE telemetry_raw (
    time TIMESTAMPTZ NOT NULL,
    session_uid UUID NOT NULL,
    lap_number INT NOT NULL,
    signal_name TEXT NOT NULL,
    value DOUBLE PRECISION NOT NULL
);

-- 4. Convert table to a TimescaleDB Hypertable partitioned by time slices
SELECT create_hypertable('telemetry_raw', 'time', chunk_time_interval => INTERVAL '1 day');

-- 5. Performance Composite Indexing
CREATE INDEX idx_telemetry_lookup 
ON telemetry_raw (session_uid, signal_name, time DESC);

-- 6. Configure Columnar Compression Matrix
ALTER TABLE telemetry_raw SET (
    timescaledb.compress,
    timescaledb.compress_segmentby = 'session_uid, signal_name',
    timescaledb.compress_orderby = 'time DESC'
);

-- 7. Establish Background Automation Policies
-- Compress any partition chunks that contain data older than 2 hours
DO $$
BEGIN
  PERFORM add_compression_policy('telemetry_raw', INTERVAL '2 hours');
EXCEPTION
  WHEN duplicate_object THEN NULL;
  WHEN undefined_function THEN
    RAISE NOTICE 'Timescale policy function unavailable: add_compression_policy';
END $$;

-- 8. Writable Ingestion View & Trigger for Sessions UPSERT
CREATE OR REPLACE VIEW sessions_ingest_view AS
SELECT
  uid,
  session_name,
  vehicle_setup
FROM sessions;

CREATE OR REPLACE FUNCTION upsert_session_ingest()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO sessions (
    uid,
    session_name,
    vehicle_setup
  )
  VALUES (
    NEW.uid,
    COALESCE(NEW.session_name, 'UNKNOWN_SESSION'),
    NEW.vehicle_setup
  )
  ON CONFLICT (uid)
  DO UPDATE SET
    session_name = COALESCE(EXCLUDED.session_name, sessions.session_name),
    vehicle_setup = EXCLUDED.vehicle_setup;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trigger_upsert_session_ingest ON sessions_ingest_view;
CREATE TRIGGER trigger_upsert_session_ingest
INSTEAD OF INSERT ON sessions_ingest_view
FOR EACH ROW
EXECUTE FUNCTION upsert_session_ingest();

