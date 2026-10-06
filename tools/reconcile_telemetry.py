"""Compare v2 metric CSV identities; archive duplicates are expected and counted."""
import argparse
import csv
import json
import uuid
from datetime import datetime, timezone
from pathlib import Path

def timestamp(value):
    stamp = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if stamp.tzinfo is None:
        raise ValueError("Reconciliation requires timezone-aware timestamps")
    return stamp.astimezone(timezone.utc).isoformat()

def identity(row):
    return (str(uuid.UUID(row["session_uid"])), int(row["seq_in_session"]),
            timestamp(row.get("ts_wall_utc", row.get("time", ""))))

def content(row):
    """Normalize wire/CSV/SQL types; receipt time is deliberately not immutable."""
    def optional(key):
        value = row.get(key)
        return None if value is None or value == "" else value
    def integer(key, default=None):
        value = optional(key)
        return default if value is None else int(value)
    return (identity(row), integer("schema_version", 2),
            timestamp(row.get("observed_at_utc", row.get("observed_at", ""))),
            integer("ts_session_ms"), integer("lap_number"),
            optional("session_state"), optional("lap_phase"), optional("signal_name"),
            float(row["value"]), optional("unit"), optional("source"),
            optional("quality"), optional("sample_kind"), optional("source_sample_id"),
            integer("can_id"), integer("freshness_ms", 5000))

def load_rows(paths):
    rows = []
    for path in paths:
        with Path(path).open(newline="", encoding="utf-8-sig") as stream:
            rows.extend(csv.DictReader(stream))
    return rows

def reconcile(expected, actual):
    expected_map = {}
    for row in expected:
        key = identity(row)
        if key in expected_map and content(row) != content(expected_map[key]):
            raise ValueError("Conflicting expected identity: " + str(key))
        expected_map[key] = row
    actual_map = {}
    conflicts = []
    for row in actual:
        key = identity(row)
        original = expected_map.get(key, actual_map.get(key))
        if original is not None and content(row) != content(original):
            conflicts.append(key)
        actual_map[key] = row
    return {"missing": sorted(expected_map.keys() - actual_map.keys()),
            "unexpected": sorted(actual_map.keys() - expected_map.keys()),
            "conflicts": conflicts, "duplicates": len(actual) - len(actual_map),
            "expected": len(expected_map), "actual": len(actual_map)}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--expected", required=True, help="v2 JSON event array/envelope or CSV")
    parser.add_argument("actual", nargs="+", help="CSV archives or SQL telemetry_samples CSV export")
    args = parser.parse_args()
    path = Path(args.expected)
    expected = json.loads(path.read_text()) if path.suffix == ".json" else load_rows([path])
    if isinstance(expected, dict):
        expected = expected["events"]
    expected = [r for r in expected if "signal_name" in r]
    result = reconcile(expected, load_rows(args.actual))
    print(json.dumps(result, indent=2))
    raise SystemExit(bool(result["missing"] or result["unexpected"] or result["conflicts"]))

if __name__ == "__main__":
    main()
