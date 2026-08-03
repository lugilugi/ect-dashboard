#!/usr/bin/env python3
"""Continuous MQTT -> CSV logger for the ECT backend.

Subscribes to the telemetry event/session topics and appends each decoded
signal as a row in a per-session CSV under EXPORT_DIR. Rows are buffered and
fsynced once per second, so a sudden container kill loses at most ~1s of rows
and never corrupts earlier data (append-only, line-oriented CSV).

No retention: every CSV file is kept indefinitely.
"""

import csv
import io
import json
import os
import signal
import threading
from collections import OrderedDict
from datetime import datetime, timezone

EXPORT_DIR = os.environ.get("EXPORT_DIR", "/var/lib/ect-backend/exports")
MQTT_HOST = os.environ.get("MQTT_HOST", "127.0.0.1")
MQTT_PORT = int(os.environ.get("MQTT_PORT", "1883"))
TOPIC_EVENTS = os.environ.get("TOPIC_EVENTS", "telemetry/eco_archers/events")
TOPIC_SESSIONS = os.environ.get("TOPIC_SESSIONS", "telemetry/eco_archers/sessions")
FLUSH_INTERVAL_S = 1.0
MAX_SEEN = 100000

EVENT_COLUMNS = [
    "ts_wall_utc",
    "session_uid",
    "lap_number",
    "ts_session_ms",
    "seq_in_session_start",
    "seq_in_session_end",
    "signal_name",
    "value",
]
SESSION_COLUMNS = ["uid", "session_name", "ts_wall_utc"]
SKIP_KEYS = {
    "session_uid",
    "lap_number",
    "ts_wall_utc",
    "ts_session_ms",
    "seq_in_session_start",
    "seq_in_session_end",
}


def sanitize(value):
    return "".join(c if c.isalnum() or c in "._-" else "_" for c in str(value))


class CsvSink:
    """Append-only per-file CSV writer with duplicate suppression and fsync."""

    def __init__(self, root):
        os.makedirs(root, exist_ok=True)
        self.root = root
        self._handles = {}
        self._seen = OrderedDict()
        self._lock = threading.Lock()

    def _handle(self, name, columns):
        path = os.path.join(self.root, name)
        with self._lock:
            handle = self._handles.get(path)
            if handle:
                return handle
            new_file = not os.path.exists(path) or os.path.getsize(path) == 0
            buf = io.StringIO()
            writer = csv.writer(buf, lineterminator="\n")
            if new_file:
                writer.writerow(columns)
            handle = (writer, buf, open(path, "a", encoding="utf-8", newline=""))
            self._handles[path] = handle
            return handle

    def seen(self, key):
        with self._lock:
            if key in self._seen:
                return True
            self._seen[key] = None
            if len(self._seen) > MAX_SEEN:
                self._seen.popitem(last=False)
            return False

    def append(self, name, columns, row):
        writer, buf, fh = self._handle(name, columns)
        writer.writerow(row)
        fh.write(buf.getvalue())
        buf.seek(0)
        buf.truncate(0)

    def flush_all(self):
        with self._lock:
            for _, _, fh in self._handles.values():
                fh.flush()
                os.fsync(fh.fileno())

    def close(self):
        self.flush_all()
        with self._lock:
            for _, _, fh in self._handles.values():
                fh.close()
            self._handles.clear()


def on_connect(client, userdata, flags, rc, properties=None):
    client.subscribe([(TOPIC_EVENTS, 1), (TOPIC_SESSIONS, 1)])


def on_message(client, userdata, msg):
    try:
        payload = json.loads(msg.payload.decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        return
    if not isinstance(payload, dict):
        return

    sink = userdata["sink"]
    if msg.topic == TOPIC_EVENTS:
        uid = payload.get("session_uid", "unknown")
        seq0 = payload.get("seq_in_session_start", "")
        seq1 = payload.get("seq_in_session_end", "")
        prefix = [
            payload.get("ts_wall_utc", ""),
            uid,
            payload.get("lap_number", ""),
            payload.get("ts_session_ms", ""),
            seq0,
            seq1,
        ]
        for key, value in payload.items():
            if key in SKIP_KEYS:
                continue
            if sink.seen((uid, seq0, seq1, key)):
                continue
            sink.append(
                "events_{}.csv".format(sanitize(uid)),
                EVENT_COLUMNS,
                prefix + [key, "" if value is None else str(value)],
            )
    elif msg.topic == TOPIC_SESSIONS:
        sink.append(
            "sessions.csv",
            SESSION_COLUMNS,
            [
                payload.get("uid", ""),
                payload.get("session_name", ""),
                datetime.now(timezone.utc).isoformat(),
            ],
        )


def main():
    # Imported lazily so the module can be unit-tested without paho installed.
    import paho.mqtt.client as mqtt

    sink = CsvSink(EXPORT_DIR)
    client = mqtt.Client(client_id="ect-csv-streamer", clean_session=False)
    client.on_connect = on_connect
    client.on_message = on_message
    client.user_data_set({"sink": sink})
    client.connect(MQTT_HOST, MQTT_PORT, keepalive=30)
    client.loop_start()

    stop = threading.Event()
    signal.signal(signal.SIGTERM, lambda *_: stop.set())
    signal.signal(signal.SIGINT, lambda *_: stop.set())

    while not stop.wait(FLUSH_INTERVAL_S):
        sink.flush_all()
    sink.close()
    client.loop_stop()
    client.disconnect()


if __name__ == "__main__":
    main()
