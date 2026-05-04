-- 004_query_performance_views.sql
-- Additional query-performance indexes and operator-focused views.

CREATE INDEX IF NOT EXISTS idx_events_session_time_desc
  ON telemetry.telemetry_events (session_id, ts_wall_utc DESC);

CREATE INDEX IF NOT EXISTS idx_events_session_metric_session_ms
  ON telemetry.telemetry_events (session_id, metric_key, ts_session_ms);

CREATE INDEX IF NOT EXISTS idx_events_session_created_desc
  ON telemetry.telemetry_events (session_id, created_at_utc DESC);

CREATE INDEX IF NOT EXISTS idx_sessions_created_desc
  ON telemetry.sessions (created_at_utc DESC);

CREATE OR REPLACE VIEW telemetry.session_summary_v1 AS
SELECT
  s.session_id,
  s.session_name,
  s.session_state,
  s.ui_mode,
  s.laps_planned,
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