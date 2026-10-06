#!/usr/bin/env python3
"""Independent at-least-once v2 MQTT archive; durable flush once per second."""

import csv
import json
import os
import signal
import threading
from datetime import datetime, timezone

from telemetry_contract import (
    EVENT_COLUMNS, SESSION_COLUMNS, validate_event, validate_session,
)

EXPORT_DIR = os.environ.get("EXPORT_DIR", "/var/lib/ect-backend/exports")
MQTT_HOST = os.environ.get("MQTT_HOST", "127.0.0.1")
MQTT_PORT = int(os.environ.get("MQTT_PORT", "1883"))
TOPIC_EVENTS = os.environ.get("TOPIC_EVENTS", "telemetry/eco_archers/events")
TOPIC_SESSIONS = os.environ.get("TOPIC_SESSIONS", "telemetry/eco_archers/sessions")


class CsvSink:
    """Serialize append/flush/close; identities, not an in-memory dedup cache."""

    def __init__(self, root):
        os.makedirs(root, exist_ok=True)
        self.root = root
        self._handles = {}
        self._lock = threading.RLock()

    def append(self, name, columns, row):
        with self._lock:
            handle = self._handles.get(name)
            if handle is None:
                path = os.path.join(self.root, name)
                new = not os.path.exists(path) or os.path.getsize(path) == 0
                stream = open(path, "a", encoding="utf-8", newline="")
                writer = csv.writer(stream, lineterminator="\n")
                handle = (stream, writer)
                self._handles[name] = handle
                if new:
                    writer.writerow(columns)
            handle[1].writerow(row)

    def reject(self, topic, payload, reason):
        self.append("rejected_v2.csv", ["received_at_utc", "topic", "reason", "payload"],
                    [datetime.now(timezone.utc).isoformat(), topic, str(reason),
                     payload.decode("utf-8", errors="replace")])

    def flush_all(self):
        with self._lock:
            for stream, _ in self._handles.values():
                stream.flush()
                os.fsync(stream.fileno())

    def close(self):
        with self._lock:
            self.flush_all()
            for stream, _ in self._handles.values():
                stream.close()
            self._handles.clear()


def on_connect(client, userdata, flags, rc, properties=None):
    client.subscribe([(TOPIC_EVENTS, 1), (TOPIC_SESSIONS, 1)])


def on_message(client, userdata, msg):
    sink = userdata["sink"]
    try:
        payload = json.loads(msg.payload.decode("utf-8"))
        if not isinstance(payload, dict) or payload.get("schema_version") != 2:
            raise ValueError("unsupported envelope")
        if msg.topic == TOPIC_EVENTS:
            events = payload.get("events")
            if not isinstance(events, list) or not events:
                raise ValueError("events must be a nonempty array")
            for event in events:
                try:
                    validate_event(event)
                    uid = event["session_uid"]
                    sink.append("events_v2_" + uid + ".csv", EVENT_COLUMNS,
                                [event.get(key, "") for key in EVENT_COLUMNS])
                except (ValueError, TypeError, OverflowError) as error:
                    sink.reject(msg.topic, json.dumps(event).encode(), error)
        elif msg.topic == TOPIC_SESSIONS:
            validate_session(payload)
            sink.append("sessions_v2.csv", SESSION_COLUMNS,
                        [payload.get(key, "") for key in SESSION_COLUMNS])
    except (ValueError, TypeError, UnicodeDecodeError, OverflowError) as error:
        sink.reject(msg.topic, msg.payload, error)


def main():
    import paho.mqtt.client as mqtt

    sink = CsvSink(EXPORT_DIR)
    client = mqtt.Client(client_id=os.environ.get("CSV_CLIENT_ID", "ect-csv-v2"),
                         clean_session=False)
    client.on_connect = on_connect
    client.on_message = on_message
    client.user_data_set({"sink": sink})
    stop = threading.Event()
    signal.signal(signal.SIGTERM, lambda *_: stop.set())
    signal.signal(signal.SIGINT, lambda *_: stop.set())
    client.connect_async(MQTT_HOST, MQTT_PORT, keepalive=30)
    client.loop_start()
    try:
        while not stop.wait(1):
            sink.flush_all()
    finally:
        client.disconnect()
        client.loop_stop()
        sink.close()


if __name__ == "__main__":
    main()
