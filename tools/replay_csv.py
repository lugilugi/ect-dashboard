"""Validate/replay missing v2 metric CSV records with their original identities."""
import argparse
import json
from pathlib import Path
import sys
import uuid
from reconcile_telemetry import identity, content, load_rows

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "ops/backend"))
from telemetry_contract import validate_event

def records(paths, uid):
    result = {}
    uid = uuid.UUID(uid)
    for original in load_rows(paths):
        if uuid.UUID(original["session_uid"]) != uid:
            continue
        row = {k: v for k, v in original.items() if v != ""}
        for key in ["schema_version", "seq_in_session", "ts_session_ms", "lap_number",
                    "can_id", "freshness_ms"]:
            if key in row:
                row[key] = int(row[key])
        row["value"] = float(row["value"])
        validate_event(row)
        key = identity(row)
        if key in result and content(result[key]) != content(row):
            raise ValueError("Conflicting archived identity: " + str(key))
        result[key] = row
    return result

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("csv", nargs="+")
    parser.add_argument("--session", required=True)
    parser.add_argument("--sql-snapshot", help="Exclude identities already present in this SQL CSV export")
    parser.add_argument("--publish", action="store_true", help="Default is dry-run")
    parser.add_argument("--host")
    parser.add_argument("--port", type=int, default=1883)
    parser.add_argument("--topic", default="telemetry/eco_archers/events")
    args = parser.parse_args()
    uuid.UUID(args.session)
    desired = records(args.csv, args.session)
    present = set()
    for row in load_rows([args.sql_snapshot]) if args.sql_snapshot else []:
        key = identity(row)
        if key in desired and content(row) != content(desired[key]):
            raise ValueError("SQL contains conflicting identity; replay cannot repair: " + str(key))
        present.add(key)
    missing = [r for key, r in desired.items() if key not in present]
    print(json.dumps({"session": args.session, "records_to_replay": len(missing),
                      "mode": "publish" if args.publish else "dry-run"}))
    if not args.publish:
        return
    if not args.host:
        parser.error("--publish requires --host")
    import paho.mqtt.client as mqtt
    client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id="ect-repair-" + str(uuid.uuid4()))
    client.connect(args.host, args.port)
    client.loop_start()
    try:
        for offset in range(0, len(missing), 32):
            info = client.publish(args.topic, json.dumps({"schema_version": 2,
                                  "events": missing[offset:offset+32]}), qos=1)
            info.wait_for_publish(timeout=10)
            if not info.is_published():
                raise RuntimeError("Broker acknowledgement unavailable; safe to retry unchanged")
    finally:
        client.disconnect()
        client.loop_stop()

if __name__ == "__main__":
    main()
