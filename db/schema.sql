-- Fresh schema only. Coordinated reset is an explicit release operation.
-- Schema 3 keeps wire contract ect.telemetry.v2; see docs/implementation/cutover.md.
-- Telegraf COPY tags stay TEXT in staging tables; owned tables use typed columns.
CREATE EXTENSION IF NOT EXISTS timescaledb;

CREATE TABLE schema_metadata (
  version integer PRIMARY KEY,
  contract text NOT NULL,
  schema_sha256 text NOT NULL DEFAULT 'uninitialized',
  initialized_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
INSERT INTO schema_metadata(version,contract) VALUES (3, 'ect.telemetry.v2');

CREATE TABLE sessions (
  uid uuid PRIMARY KEY,
  session_name text NOT NULL CHECK (length(session_name) BETWEEN 1 AND 100),
  started_at timestamptz NOT NULL,
  ended_at timestamptz,
  session_state text NOT NULL CHECK (session_state IN ('IDLE','ARMED','LOGGING','ENDED')),
  laps_completed integer NOT NULL CHECK (laps_completed >= 0),
  metadata_revision bigint NOT NULL CHECK (metadata_revision > 0),
  received_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX sessions_started ON sessions(started_at DESC);

CREATE TABLE telemetry_raw (
  time timestamptz NOT NULL,
  session_uid uuid NOT NULL,
  seq_in_session bigint NOT NULL CHECK (seq_in_session > 0),
  observed_at timestamptz NOT NULL,
  ts_session_ms bigint NOT NULL CHECK (ts_session_ms >= 0),
  lap_number integer CHECK (lap_number > 0),
  session_state text NOT NULL CHECK (session_state IN ('IDLE','ARMED','LOGGING','ENDED')),
  lap_phase text,
  signal_name text NOT NULL CHECK (length(signal_name) BETWEEN 1 AND 128),
  value double precision NOT NULL,
  unit text CHECK (length(unit) BETWEEN 1 AND 32),
  source text NOT NULL CHECK (length(source) BETWEEN 1 AND 64),
  quality text NOT NULL CHECK (length(quality) BETWEEN 1 AND 32),
  sample_kind text NOT NULL CHECK (sample_kind IN ('observation','snapshot','diagnostic')),
  source_sample_id text CHECK (length(source_sample_id) BETWEEN 1 AND 128),
  can_id integer CHECK (can_id BETWEEN 0 AND 536870911),
  freshness_ms integer NOT NULL DEFAULT 5000 CHECK (freshness_ms > 0),
  received_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  UNIQUE(time, session_uid, seq_in_session)
);
SELECT create_hypertable('telemetry_raw', 'time', chunk_time_interval => INTERVAL '1 day');
CREATE INDEX telemetry_lookup ON telemetry_raw(session_uid, signal_name, observed_at DESC, seq_in_session DESC);
CREATE INDEX telemetry_lap_lookup ON telemetry_raw(session_uid, lap_number, time);
CREATE INDEX telemetry_lap_completed ON telemetry_raw(session_uid, lap_number, time)
  WHERE signal_name = 'Lap_Completed';
ALTER TABLE telemetry_raw SET (
  timescaledb.compress,
  timescaledb.compress_segmentby = 'session_uid,signal_name',
  timescaledb.compress_orderby = 'time DESC,seq_in_session DESC'
);
-- Late phone uploads normally land in uncompressed chunks.
SELECT add_compression_policy('telemetry_raw', INTERVAL '2 days');

CREATE TABLE ingest_rejections (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  received_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  kind text NOT NULL,
  reason text NOT NULL,
  payload jsonb NOT NULL
);

-- Ingest-maintained read models: latest value per session/signal and
-- per-session sample bounds, so dashboards and alerts never scan history.
CREATE TABLE latest_signal_values (
  LIKE telemetry_raw INCLUDING DEFAULTS,
  PRIMARY KEY (session_uid, signal_name)
);
CREATE TABLE session_bounds (
  session_uid uuid PRIMARY KEY,
  first_sample_at timestamptz NOT NULL,
  last_sample_at timestamptz NOT NULL,
  last_received_at timestamptz NOT NULL  -- server clock, for stall detection
);

-- Plain TEXT staging tables written by Telegraf COPY. The plugin's time is
-- gather time, NOT array element capture time; SQL casts ts_wall_utc.
CREATE TABLE telemetry_ingest (
  staged_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  staged_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  time timestamptz, schema_version text,
  session_uid text, seq_in_session text,
  ts_wall_utc text, observed_at_utc text,
  ts_session_ms text, lap_number text,
  session_state text, lap_phase text,
  signal_name text, value double precision,
  unit text, source text, quality text,
  sample_kind text, source_sample_id text,
  can_id text, freshness_ms text
) WITH (autovacuum_vacuum_scale_factor = 0, autovacuum_vacuum_threshold = 20000);

CREATE TABLE sessions_ingest (
  staged_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  staged_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  time timestamptz, schema_version text,
  uid text, session_name text,
  started_at_utc text, ended_at_utc text,
  session_state text, laps_completed text,
  metadata_revision text
);

-- One set-based pass over claimed staging rows [p_from, p_to]. Validation
-- mirrors every cast and CHECK so valid neighbors never share a failure.
-- Staging statistics are always stale (the table is emptied every second), so
-- CTE estimates are ~1 row; disabling nested loops keeps batch self-joins
-- hashed instead of quadratic. The stored-row probe is LATERAL and unaffected.
CREATE FUNCTION ingest_metric_range(p_from bigint, p_to bigint) RETURNS bigint
LANGUAGE plpgsql SET search_path = pg_catalog, public, pg_temp SET enable_nestloop = off AS $$
DECLARE n_claimed bigint; n_invalid bigint; n_redelivered bigint; n_inserted bigint;
BEGIN
  WITH claimed AS (
    DELETE FROM telemetry_ingest WHERE staged_id BETWEEN p_from AND p_to RETURNING *
  ), checked AS MATERIALIZED (
    SELECT c.*,
      CASE
        WHEN c.schema_version IS DISTINCT FROM '2' THEN 'unsupported schema_version'
        WHEN c.session_uid IS NULL OR NOT pg_input_is_valid(c.session_uid, 'uuid') THEN 'invalid session_uid'
        WHEN CASE WHEN pg_input_is_valid(c.seq_in_session, 'bigint')
               THEN c.seq_in_session::bigint < 1 ELSE true END THEN 'invalid seq_in_session'
        WHEN c.ts_wall_utc IS NULL OR c.ts_wall_utc !~ 'Z$'
          OR NOT pg_input_is_valid(c.ts_wall_utc, 'timestamptz') THEN 'invalid ts_wall_utc'
        WHEN c.observed_at_utc IS NULL OR c.observed_at_utc !~ 'Z$'
          OR NOT pg_input_is_valid(c.observed_at_utc, 'timestamptz') THEN 'invalid observed_at_utc'
        WHEN CASE WHEN pg_input_is_valid(c.ts_session_ms, 'bigint')
               THEN c.ts_session_ms::bigint < 0 ELSE true END THEN 'invalid ts_session_ms'
        WHEN c.lap_number IS NOT NULL AND CASE WHEN pg_input_is_valid(c.lap_number, 'integer')
               THEN c.lap_number::integer < 1 ELSE true END THEN 'invalid lap_number'
        WHEN c.session_state IS NULL
          OR c.session_state NOT IN ('IDLE','ARMED','LOGGING','ENDED') THEN 'invalid session_state'
        WHEN c.signal_name IS NULL OR length(c.signal_name) NOT BETWEEN 1 AND 128 THEN 'invalid signal_name'
        WHEN c.value IS NULL
          OR c.value IN ('NaN'::float8, 'Infinity'::float8, '-Infinity'::float8) THEN 'invalid value'
        WHEN c.unit IS NOT NULL AND length(c.unit) NOT BETWEEN 1 AND 32 THEN 'invalid unit'
        WHEN c.source IS NULL OR length(c.source) NOT BETWEEN 1 AND 64 THEN 'invalid source'
        WHEN c.quality IS NULL OR length(c.quality) NOT BETWEEN 1 AND 32 THEN 'invalid quality'
        WHEN c.sample_kind IS NULL
          OR c.sample_kind NOT IN ('observation','snapshot','diagnostic') THEN 'invalid sample_kind'
        WHEN c.source_sample_id IS NOT NULL
          AND length(c.source_sample_id) NOT BETWEEN 1 AND 128 THEN 'invalid source_sample_id'
        WHEN c.can_id IS NOT NULL AND CASE WHEN pg_input_is_valid(c.can_id, 'integer')
               THEN c.can_id::integer NOT BETWEEN 0 AND 536870911 ELSE true END THEN 'invalid can_id'
        WHEN c.freshness_ms IS NOT NULL AND CASE WHEN pg_input_is_valid(c.freshness_ms, 'integer')
               THEN c.freshness_ms::integer < 1 ELSE true END THEN 'invalid freshness_ms'
      END AS reason
    FROM claimed c
  ), typed AS MATERIALIZED (
    SELECT t.*, row_number() OVER (PARTITION BY t.time, t.session_uid, t.seq_in_session
                                   ORDER BY t.staged_id) AS arrival
    FROM (
      SELECT staged_id, staged_at,
        ts_wall_utc::timestamptz AS time, session_uid::uuid AS session_uid,
        seq_in_session::bigint AS seq_in_session, observed_at_utc::timestamptz AS observed_at,
        ts_session_ms::bigint AS ts_session_ms, lap_number::integer AS lap_number,
        session_state, lap_phase, signal_name, value, unit, source, quality, sample_kind,
        source_sample_id, can_id::integer AS can_id,
        COALESCE(freshness_ms::integer, 5000) AS freshness_ms
      FROM checked WHERE reason IS NULL
    ) t
  ), stored AS MATERIALIZED (
    -- Probe the identity unique index BEFORE inserting, so the INSERT never
    -- targets an existing key. On TimescaleDB 2.17 a multi-row ON CONFLICT
    -- that hits a compressed chunk can drop, or omit from RETURNING, other
    -- rows of the same statement. The advisory lock serializes every writer.
    SELECT e.* FROM typed t
    CROSS JOIN LATERAL (SELECT * FROM telemetry_raw r WHERE r.time = t.time
      AND r.session_uid = t.session_uid AND r.seq_in_session = t.seq_in_session LIMIT 1) e
    WHERE t.arrival = 1
  ), fresh AS MATERIALIZED (
    SELECT t.* FROM typed t
    WHERE t.arrival = 1 AND NOT EXISTS (SELECT 1 FROM stored s WHERE s.time = t.time
      AND s.session_uid = t.session_uid AND s.seq_in_session = t.seq_in_session)
  ), inserted AS (
    -- ON CONFLICT is only a backstop; the invariant below catches any loss.
    INSERT INTO telemetry_raw(time, session_uid, seq_in_session, observed_at, ts_session_ms,
      lap_number, session_state, lap_phase, signal_name, value, unit, source, quality,
      sample_kind, source_sample_id, can_id, freshness_ms, received_at)
    SELECT time, session_uid, seq_in_session, observed_at, ts_session_ms, lap_number,
      session_state, lap_phase, signal_name, value, unit, source, quality, sample_kind,
      source_sample_id, can_id, freshness_ms, staged_at
    FROM fresh ORDER BY time
    ON CONFLICT (time, session_uid, seq_in_session) DO NOTHING
    RETURNING *
  ), conflicts AS (
    -- Redelivery of a stored identity/time: compare every arrival with it.
    SELECT t.staged_id FROM typed t
    JOIN stored e USING (time, session_uid, seq_in_session)
    WHERE ROW(t.observed_at, t.ts_session_ms, t.lap_number, t.session_state, t.lap_phase,
              t.signal_name, t.value, t.unit, t.source, t.quality, t.sample_kind,
              t.source_sample_id, t.can_id, t.freshness_ms)
      IS DISTINCT FROM
          ROW(e.observed_at, e.ts_session_ms, e.lap_number, e.session_state, e.lap_phase,
              e.signal_name, e.value, e.unit, e.source, e.quality, e.sample_kind,
              e.source_sample_id, e.can_id, e.freshness_ms)
    UNION ALL
    -- Redelivery of a new identity within this batch: compare with first arrival.
    SELECT t.staged_id FROM typed t
    JOIN fresh f USING (time, session_uid, seq_in_session)
    WHERE t.arrival > 1
      AND ROW(t.observed_at, t.ts_session_ms, t.lap_number, t.session_state, t.lap_phase,
              t.signal_name, t.value, t.unit, t.source, t.quality, t.sample_kind,
              t.source_sample_id, t.can_id, t.freshness_ms)
      IS DISTINCT FROM
          ROW(f.observed_at, f.ts_session_ms, f.lap_number, f.session_state, f.lap_phase,
              f.signal_name, f.value, f.unit, f.source, f.quality, f.sample_kind,
              f.source_sample_id, f.can_id, f.freshness_ms)
  ), rejected AS (
    -- Payloads are built only for rejected rows: the staged TEXT record.
    INSERT INTO ingest_rejections(received_at, kind, reason, payload)
    SELECT c.staged_at, 'metric', COALESCE(c.reason, 'conflicting duplicate'),
      to_jsonb(c) - 'staged_id' - 'staged_at' - 'reason'
    FROM checked c
    WHERE c.reason IS NOT NULL OR c.staged_id IN (SELECT staged_id FROM conflicts)
    RETURNING 1
  ), latest AS (
    INSERT INTO latest_signal_values AS l
    SELECT DISTINCT ON (session_uid, signal_name) * FROM inserted
    WHERE sample_kind <> 'diagnostic'
    ORDER BY session_uid, signal_name, observed_at DESC, seq_in_session DESC
    ON CONFLICT (session_uid, signal_name) DO UPDATE SET
      (time, seq_in_session, observed_at, ts_session_ms, lap_number, session_state, lap_phase,
       value, unit, source, quality, sample_kind, source_sample_id, can_id, freshness_ms,
       received_at) =
      (EXCLUDED.time, EXCLUDED.seq_in_session, EXCLUDED.observed_at, EXCLUDED.ts_session_ms,
       EXCLUDED.lap_number, EXCLUDED.session_state, EXCLUDED.lap_phase, EXCLUDED.value,
       EXCLUDED.unit, EXCLUDED.source, EXCLUDED.quality, EXCLUDED.sample_kind,
       EXCLUDED.source_sample_id, EXCLUDED.can_id, EXCLUDED.freshness_ms, EXCLUDED.received_at)
    WHERE (EXCLUDED.observed_at, EXCLUDED.seq_in_session) > (l.observed_at, l.seq_in_session)
    RETURNING 1
  ), bounds AS (
    INSERT INTO session_bounds AS b
    SELECT session_uid, min(time), max(time), max(received_at) FROM inserted GROUP BY session_uid
    ON CONFLICT (session_uid) DO UPDATE SET
      first_sample_at = LEAST(b.first_sample_at, EXCLUDED.first_sample_at),
      last_sample_at = GREATEST(b.last_sample_at, EXCLUDED.last_sample_at),
      last_received_at = GREATEST(b.last_received_at, EXCLUDED.last_received_at)
    RETURNING 1
  )
  SELECT (SELECT count(*) FROM claimed),
         (SELECT count(*) FROM checked WHERE reason IS NOT NULL),
         (SELECT count(*) FROM typed) - (SELECT count(*) FROM fresh),
         (SELECT count(*) FROM inserted)
    INTO n_claimed, n_invalid, n_redelivered, n_inserted;
  -- Every claimed row is inserted, a redelivery, or rejected as invalid.
  -- Otherwise roll back (rows stay staged) rather than lose data silently.
  IF n_inserted + n_redelivered + n_invalid <> n_claimed THEN
    RAISE EXCEPTION 'ingest invariant violated: claimed % = inserted % + redelivered % + invalid % fails',
      n_claimed, n_inserted, n_redelivered, n_invalid USING ERRCODE = 'XX000';
  END IF;
  RETURN n_claimed;
END $$;

-- Highest revision wins; equal revisions keep first arrival and diagnose
-- differing content exactly as sequential per-record processing would.
CREATE FUNCTION ingest_session_range(p_from bigint, p_to bigint) RETURNS bigint
LANGUAGE plpgsql SET search_path = pg_catalog, public, pg_temp SET enable_nestloop = off AS $$
DECLARE processed bigint;
BEGIN
  WITH claimed AS (
    DELETE FROM sessions_ingest WHERE staged_id BETWEEN p_from AND p_to RETURNING *
  ), checked AS MATERIALIZED (
    SELECT c.staged_id, c.staged_at, c.uid, c.session_name, c.started_at_utc, c.ended_at_utc,
      c.session_state, c.laps_completed, c.metadata_revision,
      to_jsonb(c) - 'staged_id' - 'staged_at' AS payload,
      CASE
        WHEN c.schema_version IS DISTINCT FROM '2' THEN 'unsupported schema_version'
        WHEN c.uid IS NULL OR NOT pg_input_is_valid(c.uid, 'uuid') THEN 'invalid uid'
        WHEN c.session_name IS NULL OR length(c.session_name) NOT BETWEEN 1 AND 100 THEN 'invalid session_name'
        WHEN c.started_at_utc IS NULL OR c.started_at_utc !~ 'Z$'
          OR NOT pg_input_is_valid(c.started_at_utc, 'timestamptz') THEN 'invalid started_at_utc'
        WHEN c.ended_at_utc IS NOT NULL AND (c.ended_at_utc !~ 'Z$'
          OR NOT pg_input_is_valid(c.ended_at_utc, 'timestamptz')) THEN 'invalid ended_at_utc'
        WHEN c.session_state IS NULL
          OR c.session_state NOT IN ('IDLE','ARMED','LOGGING','ENDED') THEN 'invalid session_state'
        WHEN c.session_state = 'ENDED' AND c.ended_at_utc IS NULL THEN 'ended session requires end time'
        WHEN CASE WHEN pg_input_is_valid(c.laps_completed, 'integer')
               THEN c.laps_completed::integer < 0 ELSE true END THEN 'invalid laps_completed'
        WHEN CASE WHEN pg_input_is_valid(c.metadata_revision, 'bigint')
               THEN c.metadata_revision::bigint < 1 ELSE true END THEN 'invalid metadata_revision'
      END AS reason
    FROM claimed c
  ), typed AS MATERIALIZED (
    SELECT t.*,
      row_number() OVER (PARTITION BY uid, revision ORDER BY staged_id) AS revision_arrival,
      row_number() OVER (PARTITION BY uid ORDER BY revision DESC, staged_id) AS winner,
      max(revision) OVER (PARTITION BY uid ORDER BY staged_id
                          ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS prior_revision
    FROM (
      SELECT staged_id, staged_at, payload, uid::uuid AS uid, session_name,
        started_at_utc::timestamptz AS started_at, ended_at_utc::timestamptz AS ended_at,
        session_state, laps_completed::integer AS laps_completed,
        metadata_revision::bigint AS revision
      FROM checked WHERE reason IS NULL
    ) t
  ), applied AS (
    INSERT INTO sessions AS s(uid, session_name, started_at, ended_at, session_state,
                              laps_completed, metadata_revision, received_at, updated_at)
    SELECT uid, session_name, started_at, ended_at, session_state, laps_completed, revision,
      staged_at, staged_at
    FROM typed WHERE winner = 1
    ON CONFLICT (uid) DO UPDATE SET
      session_name = EXCLUDED.session_name, started_at = EXCLUDED.started_at,
      ended_at = EXCLUDED.ended_at, session_state = EXCLUDED.session_state,
      laps_completed = EXCLUDED.laps_completed,
      metadata_revision = EXCLUDED.metadata_revision, updated_at = clock_timestamp()
    WHERE EXCLUDED.metadata_revision > s.metadata_revision
    RETURNING 1
  ), conflicts AS (
    -- At its arrival the record's revision equalled the current revision:
    -- compare with the stored row, or with that revision's first batch arrival.
    SELECT t.staged_at, t.payload FROM typed t
    LEFT JOIN sessions s ON s.uid = t.uid
    LEFT JOIN typed f ON f.uid = t.uid AND f.revision = t.revision AND f.revision_arrival = 1
    WHERE GREATEST(s.metadata_revision, t.prior_revision) = t.revision
      AND CASE WHEN s.metadata_revision = t.revision
        THEN ROW(s.session_name, s.started_at, s.ended_at, s.session_state, s.laps_completed)
             IS DISTINCT FROM
             ROW(t.session_name, t.started_at, t.ended_at, t.session_state, t.laps_completed)
        ELSE ROW(f.session_name, f.started_at, f.ended_at, f.session_state, f.laps_completed)
             IS DISTINCT FROM
             ROW(t.session_name, t.started_at, t.ended_at, t.session_state, t.laps_completed)
      END
  ), rejected AS (
    INSERT INTO ingest_rejections(received_at, kind, reason, payload)
    SELECT staged_at, 'session', reason, payload FROM checked WHERE reason IS NOT NULL
    UNION ALL
    SELECT staged_at, 'session', 'conflicting duplicate revision', payload FROM conflicts
    RETURNING 1
  )
  SELECT count(*) INTO processed FROM checked;
  RETURN processed;
END $$;

-- Claims the oldest committed staging rows up to batch_limit. A batch failing
-- with a data/integrity error is retried row by row so only offending rows are
-- quarantined; operational errors roll back and stay staged for the next run.
CREATE FUNCTION ingest_staged_batch(kind text, batch_limit integer) RETURNS bigint
LANGUAGE plpgsql SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE lo bigint; hi bigint; n bigint; row_id bigint;
  staging text := CASE WHEN kind = 'metric' THEN 'telemetry_ingest' ELSE 'sessions_ingest' END;
BEGIN
  -- Serializes the scheduled job with manual CALLs; released at COMMIT.
  PERFORM pg_advisory_xact_lock(hashtext('ect.ingest_staged'));
  EXECUTE format('SELECT min(staged_id), max(staged_id), count(*) FROM
    (SELECT staged_id FROM %I ORDER BY staged_id LIMIT $1) s', staging)
    INTO lo, hi, n USING batch_limit;
  IF n = 0 THEN RETURN 0; END IF;
  BEGIN
    IF kind = 'metric' THEN PERFORM ingest_metric_range(lo, hi);
    ELSE PERFORM ingest_session_range(lo, hi); END IF;
  EXCEPTION WHEN data_exception OR integrity_constraint_violation THEN
    FOR row_id IN EXECUTE format('SELECT staged_id FROM %I WHERE staged_id BETWEEN $1 AND $2
                                  ORDER BY staged_id', staging) USING lo, hi LOOP
      BEGIN
        IF kind = 'metric' THEN PERFORM ingest_metric_range(row_id, row_id);
        ELSE PERFORM ingest_session_range(row_id, row_id); END IF;
      EXCEPTION WHEN data_exception OR integrity_constraint_violation THEN
        EXECUTE format('WITH d AS (DELETE FROM %I WHERE staged_id = $1 RETURNING *)
          INSERT INTO ingest_rejections(received_at, kind, reason, payload)
          SELECT d.staged_at, $2, $3, to_jsonb(d) - ''staged_id'' - ''staged_at'' FROM d', staging)
          USING row_id, kind, SQLERRM;
      END;
    END LOOP;
  END;
  RETURN n;
END $$;

-- TimescaleDB job entry point; also CALLable directly. Commits per batch.
CREATE PROCEDURE ingest_staged(job_id integer DEFAULT NULL, config jsonb DEFAULT NULL)
LANGUAGE plpgsql AS $$
DECLARE batch_limit constant integer := 20000; sessions_n bigint; metrics_n bigint;
BEGIN
  LOOP
    sessions_n := public.ingest_staged_batch('session', batch_limit);
    metrics_n := public.ingest_staged_batch('metric', batch_limit);
    COMMIT;
    EXIT WHEN sessions_n < batch_limit AND metrics_n < batch_limit;
  END LOOP;
END $$;
SELECT add_job('ingest_staged', INTERVAL '1 second', fixed_schedule => false);

CREATE VIEW ingest_status AS
SELECT 'metric' AS kind, count(*) AS staged_rows, min(staged_at) AS oldest_staged_at
FROM telemetry_ingest
UNION ALL
SELECT 'session', count(*), min(staged_at) FROM sessions_ingest;

CREATE VIEW telemetry_samples AS SELECT * FROM telemetry_raw;
-- Original source observations only: no sampler snapshots; plot by observed_at.
CREATE VIEW telemetry_observations AS
SELECT * FROM telemetry_raw WHERE sample_kind = 'observation';

CREATE VIEW session_catalog AS
SELECT COALESCE(s.uid, b.session_uid) AS uid,
  COALESCE(s.session_name, b.session_uid::text) AS session_name,
  COALESCE(s.started_at, b.first_sample_at) AS started_at,
  s.ended_at, s.session_state, s.laps_completed, s.metadata_revision,
  b.first_sample_at, b.last_sample_at, b.last_received_at
FROM sessions s FULL JOIN session_bounds b ON b.session_uid = s.uid;

-- Alerts follow the newest session, from the two small catalog tables only
-- (never telemetry history). A session whose metadata is still in transit is
-- found by its first sample; its session_state is then NULL (unknown).
CREATE VIEW latest_session AS
SELECT * FROM session_catalog ORDER BY started_at DESC, uid DESC LIMIT 1;

CREATE VIEW latest_signals AS
SELECT l.*,
  l.observed_at <= clock_timestamp() + INTERVAL '1 second'
  AND l.observed_at >= clock_timestamp() - l.freshness_ms * INTERVAL '1 millisecond'
  AND l.quality = 'ok' AS is_fresh
FROM latest_signal_values l;

CREATE VIEW lap_bounds AS
WITH crossings AS (
  SELECT session_uid,lap_number,min(time) AS ended_at,min(ts_session_ms) AS ended_ms
  FROM telemetry_raw WHERE signal_name='Lap_Completed' AND sample_kind='diagnostic'
  GROUP BY session_uid,lap_number
), numbered AS (
  SELECT *,lag(ended_at) OVER(PARTITION BY session_uid ORDER BY lap_number) AS previous_end,
    lag(ended_ms,1,0::bigint) OVER(PARTITION BY session_uid ORDER BY lap_number) AS previous_ms
  FROM crossings
)
SELECT n.session_uid,n.lap_number,COALESCE(n.previous_end,s.started_at) AS started_at,
  n.ended_at,(n.ended_ms-n.previous_ms)/1000.0 AS duration_seconds
FROM numbered n LEFT JOIN sessions s ON s.uid=n.session_uid;

CREATE VIEW accumulator_deltas AS
WITH ordered AS (
  SELECT *,lag(value) OVER(PARTITION BY session_uid,signal_name
      ORDER BY ts_session_ms,seq_in_session) AS previous_value
  FROM telemetry_raw WHERE signal_name IN ('Joules_780','Distance_Km') AND quality='ok'
    AND sample_kind='observation'
)
SELECT *,CASE WHEN previous_value IS NULL THEN NULL
  WHEN value >= previous_value THEN value-previous_value ELSE GREATEST(value,0) END AS delta
FROM ordered;

CREATE VIEW session_totals AS
SELECT session_uid,
  sum(delta) FILTER(WHERE signal_name='Joules_780') AS energy_j,
  sum(delta) FILTER(WHERE signal_name='Distance_Km') AS distance_km
FROM accumulator_deltas GROUP BY session_uid;

CREATE VIEW lap_totals AS
SELECT session_uid,lap_number,
  sum(delta) FILTER(WHERE signal_name='Joules_780') AS energy_j,
  sum(delta) FILTER(WHERE signal_name='Distance_Km') AS distance_km
FROM accumulator_deltas GROUP BY session_uid,lap_number;

CREATE VIEW gps_fixes AS
SELECT session_uid,source,source_sample_id,max(observed_at) AS time,
  max(lap_number) AS lap_number,
  max(value) FILTER(WHERE signal_name='GPS_Latitude_Deg') AS latitude,
  max(value) FILTER(WHERE signal_name='GPS_Longitude_Deg') AS longitude
FROM telemetry_raw
WHERE source_sample_id IS NOT NULL AND quality='ok' AND sample_kind='observation'
  AND signal_name IN ('GPS_Latitude_Deg','GPS_Longitude_Deg')
GROUP BY session_uid,source,source_sample_id
HAVING count(DISTINCT signal_name)=2;

-- Each original observation holds its value until the signal's next
-- observation, capped at freshness_ms: change-suppressed steady values keep
-- their weight and outages are never interpolated. A non-ok observation ends
-- the previous hold and contributes nothing. Snapshots are excluded.
CREATE VIEW observation_intervals AS
SELECT session_uid, lap_number, signal_name, value, starts_at, ends_at
FROM (
  SELECT session_uid, lap_number, signal_name, value, quality, observed_at AS starts_at,
    LEAST(lead(observed_at) OVER (PARTITION BY session_uid, signal_name
                                  ORDER BY observed_at, seq_in_session),
          observed_at + freshness_ms * INTERVAL '1 millisecond') AS ends_at
  FROM telemetry_raw WHERE sample_kind = 'observation'
) o
WHERE quality = 'ok' AND ends_at > starts_at;

-- Shared one-second time-weighted estimates over available observations.
-- NULL means a required signal had no valid held value in that second. A
-- second split by a lap boundary or an outage yields partial rows: weight
-- aggregates by the *_coverage_s columns (held seconds within the bucket,
-- power = min of voltage/current coverage) rather than counting rows.
CREATE VIEW telemetry_seconds AS
SELECT i.session_uid, i.lap_number, b.time,
  sum(i.value*w.seconds) FILTER(WHERE i.signal_name='Speed_Kmh')
    / NULLIF(sum(w.seconds) FILTER(WHERE i.signal_name='Speed_Kmh'),0) AS speed_kmh,
  sum(i.value*w.seconds) FILTER(WHERE i.signal_name='Voltage_780')
    / NULLIF(sum(w.seconds) FILTER(WHERE i.signal_name='Voltage_780'),0) AS voltage_v,
  sum(i.value*w.seconds) FILTER(WHERE i.signal_name='Current_780')
    / NULLIF(sum(w.seconds) FILTER(WHERE i.signal_name='Current_780'),0) AS current_a,
  max(i.value) FILTER(WHERE i.signal_name='Throttle_Percent') AS throttle_percent,
  max(i.value) FILTER(WHERE i.signal_name='Brake_Active') AS brake_active,
  sum(i.value*w.seconds) FILTER(WHERE i.signal_name='Throttle_Percent')
    / NULLIF(sum(w.seconds) FILTER(WHERE i.signal_name='Throttle_Percent'),0) AS throttle_mean_percent,
  COALESCE(sum(w.seconds) FILTER(WHERE i.signal_name='Speed_Kmh'),0) AS speed_coverage_s,
  LEAST(COALESCE(sum(w.seconds) FILTER(WHERE i.signal_name='Voltage_780'),0),
        COALESCE(sum(w.seconds) FILTER(WHERE i.signal_name='Current_780'),0)) AS power_coverage_s,
  COALESCE(sum(w.seconds) FILTER(WHERE i.signal_name='Throttle_Percent'),0) AS throttle_coverage_s
FROM observation_intervals i
CROSS JOIN LATERAL generate_series(time_bucket('1 second', i.starts_at),
  i.ends_at - INTERVAL '1 microsecond', INTERVAL '1 second') AS b(time)
CROSS JOIN LATERAL (SELECT EXTRACT(EPOCH FROM LEAST(i.ends_at, b.time + INTERVAL '1 second')
                                            - GREATEST(i.starts_at, b.time))::double precision
                      AS seconds) w
WHERE i.signal_name IN ('Speed_Kmh','Voltage_780','Current_780','Throttle_Percent','Brake_Active')
GROUP BY i.session_uid, i.lap_number, b.time;

CREATE VIEW lap_analytics AS
WITH observed AS (
  SELECT DISTINCT session_uid,lap_number FROM telemetry_raw WHERE lap_number IS NOT NULL
), stats AS (
  -- Weighted by covered duration, so partial seconds count only their share.
  SELECT session_uid,lap_number,
    sum(speed_kmh*speed_coverage_s)/NULLIF(sum(speed_coverage_s) FILTER(WHERE speed_kmh IS NOT NULL),0) AS avg_speed_kmh,
    max(speed_kmh) AS max_speed_kmh,
    sum(voltage_v*current_a*power_coverage_s)
      /NULLIF(sum(power_coverage_s) FILTER(WHERE voltage_v IS NOT NULL AND current_a IS NOT NULL),0) AS avg_power_w,
    max(voltage_v*current_a) AS peak_power_w
  FROM telemetry_seconds GROUP BY session_uid,lap_number
)
SELECT o.session_uid,o.lap_number,b.ended_at IS NOT NULL AS completed,
  b.duration_seconds,t.distance_km,t.energy_j,
  t.distance_km/NULLIF(t.energy_j/3600000.0,0) AS eff_km_per_kwh,
  s.avg_speed_kmh,s.max_speed_kmh,s.avg_power_w,s.peak_power_w
FROM observed o LEFT JOIN lap_bounds b USING(session_uid,lap_number)
LEFT JOIN lap_totals t USING(session_uid,lap_number)
LEFT JOIN stats s USING(session_uid,lap_number);
