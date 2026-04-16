-- 003_command_and_recovery_audit.sql
-- Audit tables for command TX outcomes and crash-recovery/resume diagnostics.

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
  PERFORM add_retention_policy('telemetry.tx_command_audit', INTERVAL '365 days');
EXCEPTION
  WHEN duplicate_object THEN NULL;
  WHEN undefined_function THEN
    RAISE NOTICE 'Timescale policy function unavailable: add_retention_policy';
END $$;

DO $$
BEGIN
  PERFORM add_compression_policy('telemetry.recovery_events', INTERVAL '7 days');
EXCEPTION
  WHEN duplicate_object THEN NULL;
  WHEN undefined_function THEN
    RAISE NOTICE 'Timescale policy function unavailable: add_compression_policy';
END $$;

DO $$
BEGIN
  PERFORM add_retention_policy('telemetry.recovery_events', INTERVAL '365 days');
EXCEPTION
  WHEN duplicate_object THEN NULL;
  WHEN undefined_function THEN
    RAISE NOTICE 'Timescale policy function unavailable: add_retention_policy';
END $$;
