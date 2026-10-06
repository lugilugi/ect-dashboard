# Telemetry version 2

Topics: telemetry/eco_archers/events and telemetry/eco_archers/sessions.
Version 1 is unsupported. Stop old publishers and clear dedicated queued traffic
during the coordinated cutover.

An event envelope has schema_version = 2 and an events array. Each event also
includes its version so the SQL adapter validates records independently.
Repeated signal names survive; every event carries its complete context.

~~~json
{
  "schema_version": 2,
  "events": [{
    "schema_version": 2,
    "session_uid": "11111111-1111-4111-8111-111111111111",
    "seq_in_session": 1,
    "lap_number": 1,
    "session_state": "LOGGING",
    "lap_phase": "RUNNING",
    "signal_name": "Voltage_780",
    "value": 72.4,
    "unit": "V",
    "source": "can",
    "quality": "ok",
    "sample_kind": "observation",
    "ts_wall_utc": "2026-10-06T01:00:00.000000Z",
    "observed_at_utc": "2026-10-06T01:00:00.000000Z",
    "ts_session_ms": 0
  }]
}
~~~

Required event fields are shown except unit, lap_number and lap_phase.
can_id and source_sample_id are optional. Unknown nonempty metric names are
valid. Values are finite, sequences positive and elapsed time nonnegative.
UTC timestamps are RFC3339 with Z and at most microsecond precision.

Identity is (session_uid, seq_in_session). Retrying preserves content and time;
SQL's time-partitioned unique index also includes immutable event time.
Conflicting retries are diagnosed rather than overwritten.

Observation event time is original CAN receipt/GPS time. Snapshot event time is
the sampler tick; observed_at_utc retains source time and controls freshness.
Recovery, command and lap events are diagnostic. GPS siblings share sample ID.

Sessions contain schema_version, uid, session_name, started_at_utc, nullable
ended_at_utc, session_state, laps_completed and metadata_revision. Revisions are
persisted and positive; older messages cannot revert newer state. Metadata may
arrive after metric records.

Accepted crossings emit Lap_Completed with completed lap as value/context and
exact boundary time. Session start and those events define lap bounds.

Transport and CSV are at-least-once. broker_acked does not mean SQL/CSV commit.
CSV carries the same identities, observation fields and source metadata.
