-- =============================================================================
-- ECT telemetry schema (fresh installs only; wipe the data volume to re-apply)
-- No retention policies: all telemetry is kept indefinitely.
-- =============================================================================

-- Enable TimescaleDB (required for hypertables/compression below).
CREATE EXTENSION IF NOT EXISTS timescaledb;

-- Enable UUID generation extension if not active.
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- 1. Sessions: one row per run. vehicle_setup is manual/API-only (Telegraf
--    cannot ingest nested JSON, so it is never written by the pipeline).
CREATE TABLE sessions (
    uid UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    session_name VARCHAR(100) NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    vehicle_setup JSONB
);

-- 2. Laps: optional explicit boundaries; race analysis derives laps from
--    telemetry_raw.lap_number (kept for manual/API use).
CREATE TABLE laps (
    id SERIAL PRIMARY KEY,
    session_uid UUID NOT NULL REFERENCES sessions(uid) ON DELETE CASCADE,
    lap_number INT NOT NULL,
    started_at TIMESTAMPTZ NOT NULL,
    ended_at TIMESTAMPTZ,
    UNIQUE (session_uid, lap_number)
);

-- 3. Core time-series sink: narrow EAV rows written by Telegraf COPY.
--    signal_name is intentionally free-form (any signal following the batch
--    format is accepted; nothing needs to be pre-registered).
--    NOTE ON TYPES: telegraf's outputs.postgresql plugin (>=1.31, pgx v4)
--    writes rows via COPY ... FROM STDIN BINARY, encoding every metric TAG as
--    a string against the column's declared type. Tag columns therefore MUST
--    be TEXT here; cast in queries when numeric semantics are needed.
CREATE TABLE telemetry_raw (
    time TIMESTAMPTZ NOT NULL,
    session_uid TEXT NOT NULL,
    lap_number TEXT,
    signal_name TEXT NOT NULL,
    value DOUBLE PRECISION NOT NULL,
    ts_session_ms TEXT,
    seq_in_session_start TEXT,
    seq_in_session_end TEXT
);

-- 4. Convert the sink to a TimescaleDB hypertable partitioned by time.
SELECT create_hypertable('telemetry_raw', 'time', chunk_time_interval => INTERVAL '1 day');

-- 5. Lookups used by the live overview (2s refresh) and lap analysis.
CREATE INDEX idx_telemetry_lookup
ON telemetry_raw (session_uid, signal_name, time DESC);

CREATE INDEX idx_telemetry_lap_lookup
ON telemetry_raw (session_uid, lap_number, signal_name, time DESC);

-- 6. Compression keeps the ever-growing table queryable; no data is dropped.
ALTER TABLE telemetry_raw SET (
    timescaledb.compress,
    timescaledb.compress_segmentby = 'session_uid, signal_name',
    timescaledb.compress_orderby = 'time DESC'
);

DO $$
BEGIN
  PERFORM add_compression_policy('telemetry_raw', INTERVAL '2 hours');
EXCEPTION
  WHEN duplicate_object THEN NULL;
  WHEN undefined_function THEN
    RAISE NOTICE 'Timescale policy function unavailable: add_compression_policy';
END $$;

-- 7. Writable ingestion view & trigger for session UPSERT.
--    The view is the telegraf COPY target, so its columns must match what the
--    plugin writes: uid arrives as a string (text), session_name as text.
CREATE OR REPLACE VIEW sessions_ingest_view AS
SELECT
  uid::text AS uid,
  session_name,
  vehicle_setup,
  created_at AS time
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
    NEW.uid::uuid,
    COALESCE(NEW.session_name, 'UNKNOWN_SESSION'),
    NEW.vehicle_setup
  )
  ON CONFLICT (uid)
  DO UPDATE SET
    session_name = COALESCE(EXCLUDED.session_name, sessions.session_name),
    vehicle_setup = COALESCE(EXCLUDED.vehicle_setup, sessions.vehicle_setup),
    updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trigger_upsert_session_ingest ON sessions_ingest_view;
CREATE TRIGGER trigger_upsert_session_ingest
INSTEAD OF INSERT ON sessions_ingest_view
FOR EACH ROW
EXECUTE FUNCTION upsert_session_ingest();
