#!/usr/bin/env python3
"""Independent at-least-once v2 MQTT archive; acks follow a durable flush."""

import csv
from collections import OrderedDict
import json
import os
import signal
import sys
import threading
import time
from datetime import datetime, timezone

from telemetry_contract import (
    EVENT_COLUMNS, SESSION_COLUMNS, validate_event, validate_session,
)

EXPORT_DIR = os.environ.get("EXPORT_DIR", "/var/lib/ect-backend/exports")
MQTT_HOST = os.environ.get("MQTT_HOST", "127.0.0.1")
MQTT_PORT = int(os.environ.get("MQTT_PORT", "1883"))
TOPIC_EVENTS = os.environ.get("TOPIC_EVENTS", "telemetry/eco_archers/events")
TOPIC_SESSIONS = os.environ.get("TOPIC_SESSIONS", "telemetry/eco_archers/sessions")
ACK_BATCH = 10  # half of Mosquitto max_inflight_messages (20)
ACK_INTERVAL_SECONDS = 0.2
ACK_POLL_SECONDS = 0.05


class CsvSink:
    """Serialize append/flush/close; identities, not an in-memory dedup cache."""

    def __init__(self, root):
        os.makedirs(root, exist_ok=True)
        self.root = root
        self._handles = OrderedDict()
        self._lock = threading.RLock()

    def append(self, name, columns, row):
        with self._lock:
            handle = self._handles.get(name)
            if handle is None:
                if len(self._handles) >= 32:
                    _, (old_stream, _) = self._handles.popitem(last=False)
                    old_stream.flush()
                    os.fsync(old_stream.fileno())
                    old_stream.close()
                path = os.path.join(self.root, name)
                new = not os.path.exists(path) or os.path.getsize(path) == 0
                stream = open(path, "a", encoding="utf-8", newline="")
                writer = csv.writer(stream, lineterminator="\n")
                handle = (stream, writer)
                self._handles[name] = handle
                if new:
                    writer.writerow(columns)
            self._handles.move_to_end(name)
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


class AckTracker:
    """Defer MQTT acks until the rows they produced are fsynced.

    Ack ids only mean something on the connection that delivered them, so a
    new connection drops anything still pending (the broker redelivers it).
    """

    def __init__(self, sink):
        self.sink = sink
        self.lock = threading.Lock()
        self._pending = []

    def new_connection(self):
        with self.lock:
            self._pending.clear()

    def add(self, mid, qos):
        if qos > 0:
            self._pending.append((mid, qos))

    def due(self):
        return len(self._pending) >= ACK_BATCH

    def flush_and_ack(self, client):
        with self.lock:
            # A failed flush keeps the ids pending, so they are acked by the
            # next successful flush instead of pinning broker inflight slots.
            self.sink.flush_all()
            batch, self._pending = self._pending, []
            for mid, qos in batch:
                client.ack(mid, qos)


def on_connect(client, userdata, flags, rc, properties=None):
    userdata["acks"].new_connection()
    client.subscribe([(TOPIC_EVENTS, 1), (TOPIC_SESSIONS, 1)])


def on_message(client, userdata, msg):
    acks = userdata.get("acks")
    if acks is None:  # no ack tracking (direct callers)
        _handle_message(userdata["sink"], msg)
        return
    with acks.lock:
        _handle_message(userdata["sink"], msg)
        acks.add(msg.mid, msg.qos)


def _handle_message(sink, msg):
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
    client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id=os.environ.get("CSV_CLIENT_ID", "ect-csv-v2"),
                         clean_session=False, manual_ack=True)
    client.on_connect = on_connect
    client.on_message = on_message
    acks = AckTracker(sink)
    client.user_data_set({"sink": sink, "acks": acks})
    stop = threading.Event()
    signal.signal(signal.SIGTERM, lambda *_: stop.set())
    signal.signal(signal.SIGINT, lambda *_: stop.set())
    client.connect_async(MQTT_HOST, MQTT_PORT, keepalive=30)
    client.loop_start()
    try:
        # Unacked messages hold broker inflight slots (max_inflight_messages),
        # so flush often enough that the archive never throttles delivery.
        last = time.monotonic()
        while not stop.wait(ACK_POLL_SECONDS):
            if acks.due() or time.monotonic() - last >= ACK_INTERVAL_SECONDS:
                try:
                    acks.flush_and_ack(client)
                except OSError as error:
                    print(f"csv flush failed: {error}", file=sys.stderr, flush=True)
                last = time.monotonic()
    finally:
        try:
            acks.flush_and_ack(client)
        except Exception:
            pass
        client.disconnect()
        client.loop_stop()
        sink.close()


if __name__ == "__main__":
    main()
