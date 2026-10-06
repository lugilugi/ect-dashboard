"""Version-2 archive validation; SQL validates its COPY boundary separately."""

import math
import re
import uuid
from datetime import datetime

VERSION = 2
STATES = {"IDLE", "ARMED", "LOGGING", "ENDED"}
EVENT_COLUMNS = [
    "schema_version", "session_uid", "seq_in_session", "ts_wall_utc",
    "observed_at_utc", "ts_session_ms", "lap_number", "session_state",
    "lap_phase", "signal_name", "value", "unit", "source", "quality",
    "sample_kind", "source_sample_id", "can_id", "freshness_ms",
]
SESSION_COLUMNS = [
    "schema_version", "uid", "metadata_revision", "session_name",
    "started_at_utc", "ended_at_utc", "session_state", "laps_completed",
]


def _text(record, key, limit=128):
    value = record.get(key)
    if not isinstance(value, str) or not value or len(value) > limit:
        raise ValueError("invalid " + key)
    return value


def _integer(record, key, minimum=0):
    value = record.get(key)
    if type(value) is not int or not minimum <= value <= 9223372036854775807:
        raise ValueError("invalid " + key)
    return value


def _timestamp(record, key):
    value = _text(record, key, 32)
    if not re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d{1,6})?Z", value):
        raise ValueError("invalid " + key)
    datetime.fromisoformat(value.replace("Z", "+00:00"))


def _common(record, uid_key):
    if not isinstance(record, dict) or type(record.get("schema_version")) is not int:
        raise ValueError("missing schema version")
    if record["schema_version"] != VERSION:
        raise ValueError("unsupported schema version")
    uuid.UUID(_text(record, uid_key, 36))
    if record.get("session_state") not in STATES:
        raise ValueError("invalid session_state")


def validate_event(record):
    _common(record, "session_uid")
    _integer(record, "seq_in_session", 1)
    _integer(record, "ts_session_ms")
    _timestamp(record, "ts_wall_utc")
    _timestamp(record, "observed_at_utc")
    _text(record, "signal_name")
    _text(record, "source", 64)
    _text(record, "quality", 32)
    if record.get("sample_kind") not in {"observation", "snapshot", "diagnostic"}:
        raise ValueError("invalid sample_kind")
    value = record.get("value")
    if type(value) not in (int, float) or not math.isfinite(value):
        raise ValueError("invalid value")
    for key, minimum in (("lap_number", 1), ("can_id", 0), ("freshness_ms", 1)):
        if record.get(key) is not None:
            _integer(record, key, minimum)
    for key, limit in (("unit", 32), ("source_sample_id", 128), ("lap_phase", 32)):
        if record.get(key) is not None:
            _text(record, key, limit)
    return record


def validate_session(record):
    _common(record, "uid")
    _integer(record, "metadata_revision", 1)
    _integer(record, "laps_completed")
    _text(record, "session_name", 100)
    _timestamp(record, "started_at_utc")
    if record.get("ended_at_utc") is not None:
        _timestamp(record, "ended_at_utc")
    if record["session_state"] == "ENDED" and record.get("ended_at_utc") is None:
        raise ValueError("ended session requires end time")
    return record
