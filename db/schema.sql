-- Fresh v2 schema only. Coordinated reset is an explicit release operation.
-- Telegraf COPY tags stay TEXT in ingest views; owned tables use typed columns.
CREATE EXTENSION IF NOT EXISTS timescaledb;

CREATE TABLE schema_metadata (
  version integer PRIMARY KEY,
  contract text NOT NULL,
  schema_sha256 text NOT NULL DEFAULT 'uninitialized',
  initialized_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
INSERT INTO schema_metadata(version,contract) VALUES (2, 'ect.telemetry.v2');

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
ALTER TABLE telemetry_raw SET (
  timescaledb.compress,
  timescaledb.compress_segmentby = 'session_uid,signal_name',
  timescaledb.compress_orderby = 'time DESC,seq_in_session DESC'
);
SELECT add_compression_policy('telemetry_raw', INTERVAL '2 hours');

CREATE TABLE ingest_rejections (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  received_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  kind text NOT NULL,
  reason text NOT NULL,
  payload jsonb NOT NULL
);

-- Empty typed COPY views. The plugin's time is NOT array element capture time.
CREATE VIEW telemetry_ingest_view AS SELECT
  NULL::timestamptz AS time, NULL::text AS schema_version,
  NULL::text AS session_uid, NULL::text AS seq_in_session,
  NULL::text AS ts_wall_utc, NULL::text AS observed_at_utc,
  NULL::text AS ts_session_ms, NULL::text AS lap_number,
  NULL::text AS session_state, NULL::text AS lap_phase,
  NULL::text AS signal_name, NULL::double precision AS value,
  NULL::text AS unit, NULL::text AS source, NULL::text AS quality,
  NULL::text AS sample_kind, NULL::text AS source_sample_id,
  NULL::text AS can_id, NULL::text AS freshness_ms WHERE false;

CREATE FUNCTION ingest_metric() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE candidate telemetry_raw%ROWTYPE; existing telemetry_raw%ROWTYPE;
BEGIN
  IF NEW.schema_version IS DISTINCT FROM '2'
     OR NEW.ts_wall_utc IS NULL OR NEW.ts_wall_utc !~ 'Z$'
     OR NEW.observed_at_utc IS NULL OR NEW.observed_at_utc !~ 'Z$'
     OR NEW.source IS NULL OR length(NEW.source) NOT BETWEEN 1 AND 64
     OR NEW.quality IS NULL OR length(NEW.quality) NOT BETWEEN 1 AND 32
     OR NEW.session_state IS NULL OR NEW.session_state NOT IN ('IDLE','ARMED','LOGGING','ENDED')
     OR NEW.value IS NULL
     OR NEW.value IN ('NaN'::float8,'Infinity'::float8,'-Infinity'::float8)
  THEN RAISE EXCEPTION 'invalid metric contract' USING ERRCODE = '22023'; END IF;

  candidate.time := NEW.ts_wall_utc::timestamptz;
  candidate.session_uid := NEW.session_uid::uuid;
  candidate.seq_in_session := NEW.seq_in_session::bigint;
  candidate.observed_at := NEW.observed_at_utc::timestamptz;
  candidate.ts_session_ms := NEW.ts_session_ms::bigint;
  candidate.lap_number := NEW.lap_number::integer;
  candidate.session_state := NEW.session_state;
  candidate.lap_phase := NEW.lap_phase;
  candidate.signal_name := NEW.signal_name;
  candidate.value := NEW.value;
  candidate.unit := NEW.unit;
  candidate.source := NEW.source;
  candidate.quality := NEW.quality;
  candidate.sample_kind := NEW.sample_kind;
  candidate.source_sample_id := NEW.source_sample_id;
  candidate.can_id := NEW.can_id::integer;
  candidate.freshness_ms := COALESCE(NEW.freshness_ms::integer, 5000);
  candidate.received_at := clock_timestamp();

  INSERT INTO telemetry_raw SELECT (candidate).*
    ON CONFLICT (time,session_uid,seq_in_session) DO NOTHING;
  IF NOT FOUND THEN
    SELECT * INTO existing FROM telemetry_raw
      WHERE time = candidate.time AND session_uid = candidate.session_uid
        AND seq_in_session = candidate.seq_in_session;
    IF (to_jsonb(existing) - 'received_at') IS DISTINCT FROM
       (to_jsonb(candidate) - 'received_at') THEN
      INSERT INTO ingest_rejections(kind,reason,payload)
        VALUES ('metric','conflicting duplicate',to_jsonb(NEW));
    END IF;
  END IF;
  RETURN NEW;
EXCEPTION WHEN invalid_text_representation OR invalid_parameter_value
  OR numeric_value_out_of_range OR datetime_field_overflow
  OR invalid_datetime_format OR check_violation OR not_null_violation THEN
  INSERT INTO ingest_rejections(kind,reason,payload)
    VALUES ('metric',SQLERRM,to_jsonb(NEW));
  RETURN NULL;
END $$;
CREATE TRIGGER ingest_metric_trigger INSTEAD OF INSERT ON telemetry_ingest_view
  FOR EACH ROW EXECUTE FUNCTION ingest_metric();

CREATE VIEW sessions_ingest_view AS SELECT
  NULL::timestamptz AS time, NULL::text AS schema_version,
  NULL::text AS uid, NULL::text AS session_name,
  NULL::text AS started_at_utc, NULL::text AS ended_at_utc,
  NULL::text AS session_state, NULL::text AS laps_completed,
  NULL::text AS metadata_revision WHERE false;

CREATE FUNCTION ingest_session() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE existing sessions%ROWTYPE;
BEGIN
  IF NEW.schema_version IS DISTINCT FROM '2' OR NEW.started_at_utc IS NULL
     OR NEW.started_at_utc !~ 'Z$'
     OR (NEW.ended_at_utc IS NOT NULL AND NEW.ended_at_utc !~ 'Z$')
     OR (NEW.session_state = 'ENDED' AND NEW.ended_at_utc IS NULL) THEN
    RAISE EXCEPTION 'invalid session contract' USING ERRCODE = '22023';
  END IF;
  INSERT INTO sessions(uid,session_name,started_at,ended_at,session_state,
                       laps_completed,metadata_revision)
    VALUES (NEW.uid::uuid,NEW.session_name,NEW.started_at_utc::timestamptz,
            NEW.ended_at_utc::timestamptz,NEW.session_state,
            NEW.laps_completed::integer,NEW.metadata_revision::bigint)
    ON CONFLICT (uid) DO UPDATE SET
      session_name = EXCLUDED.session_name, started_at = EXCLUDED.started_at,
      ended_at = EXCLUDED.ended_at, session_state = EXCLUDED.session_state,
      laps_completed = EXCLUDED.laps_completed,
      metadata_revision = EXCLUDED.metadata_revision, updated_at = clock_timestamp()
    WHERE EXCLUDED.metadata_revision > sessions.metadata_revision;
  IF NOT FOUND THEN
    SELECT * INTO existing FROM sessions WHERE uid = NEW.uid::uuid;
    IF existing.metadata_revision = NEW.metadata_revision::bigint AND
      ROW(existing.session_name,existing.started_at,existing.ended_at,
          existing.session_state,existing.laps_completed) IS DISTINCT FROM
      ROW(NEW.session_name,NEW.started_at_utc::timestamptz,NEW.ended_at_utc::timestamptz,
          NEW.session_state,NEW.laps_completed::integer) THEN
      INSERT INTO ingest_rejections(kind,reason,payload)
        VALUES ('session','conflicting duplicate revision',to_jsonb(NEW));
    END IF;
  END IF;
  RETURN NEW;
EXCEPTION WHEN invalid_text_representation OR invalid_parameter_value
  OR numeric_value_out_of_range OR datetime_field_overflow
  OR invalid_datetime_format OR check_violation OR not_null_violation THEN
  INSERT INTO ingest_rejections(kind,reason,payload)
    VALUES ('session',SQLERRM,to_jsonb(NEW));
  RETURN NULL;
END $$;
CREATE TRIGGER ingest_session_trigger INSTEAD OF INSERT ON sessions_ingest_view
  FOR EACH ROW EXECUTE FUNCTION ingest_session();

CREATE VIEW telemetry_samples AS SELECT * FROM telemetry_raw;
CREATE VIEW session_catalog AS
WITH bounds AS (
  SELECT session_uid, min(time) AS first_sample_at, max(time) AS last_sample_at
    FROM telemetry_raw GROUP BY session_uid
), ids AS (
  SELECT uid FROM sessions UNION SELECT session_uid FROM bounds
)
SELECT ids.uid, COALESCE(s.session_name, ids.uid::text) AS session_name,
  COALESCE(s.started_at,b.first_sample_at) AS started_at,
  s.ended_at, s.session_state, s.laps_completed, s.metadata_revision,
  b.first_sample_at,b.last_sample_at
FROM ids LEFT JOIN sessions s USING(uid) LEFT JOIN bounds b ON b.session_uid=ids.uid;

CREATE VIEW latest_signals AS
SELECT DISTINCT ON(session_uid,signal_name) *,
  observed_at <= clock_timestamp() + INTERVAL '1 second'
  AND observed_at >= clock_timestamp() - freshness_ms * INTERVAL '1 millisecond'
  AND quality = 'ok' AS is_fresh
FROM telemetry_raw
WHERE sample_kind <> 'diagnostic'
ORDER BY session_uid,signal_name,observed_at DESC,seq_in_session DESC;

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

-- Shared one-second summaries are estimates over available samples, never
-- interpolation across outages. NULL means a required signal was absent.
CREATE VIEW telemetry_seconds AS
SELECT session_uid,lap_number,time_bucket('1 second',time) AS time,
  avg(value) FILTER(WHERE signal_name='Speed_Kmh') AS speed_kmh,
  avg(value) FILTER(WHERE signal_name='Voltage_780') AS voltage_v,
  avg(value) FILTER(WHERE signal_name='Current_780') AS current_a,
  max(value) FILTER(WHERE signal_name='Throttle_Percent') AS throttle_percent,
  max(value) FILTER(WHERE signal_name='Brake_Active') AS brake_active
FROM telemetry_raw WHERE quality='ok' AND sample_kind<>'diagnostic'
GROUP BY session_uid,lap_number,time_bucket('1 second',time);

CREATE VIEW lap_analytics AS
WITH observed AS (
  SELECT DISTINCT session_uid,lap_number FROM telemetry_raw WHERE lap_number IS NOT NULL
), stats AS (
  SELECT session_uid,lap_number,avg(speed_kmh) AS avg_speed_kmh,
    max(speed_kmh) AS max_speed_kmh,avg(voltage_v*current_a) AS avg_power_w,
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
