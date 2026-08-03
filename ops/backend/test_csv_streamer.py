#!/usr/bin/env python3
"""Unit tests for the continuous MQTT -> CSV streamer."""

import csv
import json
import os
import tempfile
import unittest

import csv_streamer as mod


class _FakeMsg:
    def __init__(self, topic, payload):
        self.topic = topic
        self.payload = (
            payload
            if isinstance(payload, bytes)
            else json.dumps(payload).encode("utf-8")
        )


class CsvSinkTest(unittest.TestCase):
    def test_header_written_once_then_rows_append(self):
        with tempfile.TemporaryDirectory() as root:
            sink = mod.CsvSink(root)
            sink.append(
                "events_abc.csv",
                mod.EVENT_COLUMNS,
                ["t1", "abc", "1", "0", "1", "1", "Speed_Kmh", "31.5"],
            )
            sink.append(
                "events_abc.csv",
                mod.EVENT_COLUMNS,
                ["t2", "abc", "1", "100", "2", "2", "Speed_Kmh", "32.0"],
            )
            sink.close()

            path = os.path.join(root, "events_abc.csv")
            with open(path, newline="", encoding="utf-8") as fh:
                rows = list(csv.reader(fh))

            self.assertEqual(rows[0], mod.EVENT_COLUMNS)
            self.assertEqual(len(rows), 3)
            self.assertEqual(rows[2][7], "32.0")

    def test_event_message_writes_one_row_per_signal_and_dedupes(self):
        with tempfile.TemporaryDirectory() as root:
            sink = mod.CsvSink(root)
            payload = {
                "session_uid": "abc-123",
                "lap_number": "2",
                "ts_wall_utc": "2026-08-04T00:00:00Z",
                "ts_session_ms": "1500",
                "seq_in_session_start": "10",
                "seq_in_session_end": "11",
                "Speed_Kmh": 31.5,
                "Voltage_780": 72.1,
            }
            mod.on_message(None, {"sink": sink}, _FakeMsg(mod.TOPIC_EVENTS, payload))
            # Duplicate QoS1 redelivery of the same batch is suppressed.
            mod.on_message(None, {"sink": sink}, _FakeMsg(mod.TOPIC_EVENTS, payload))
            sink.close()

            path = os.path.join(root, "events_abc-123.csv")
            with open(path, newline="", encoding="utf-8") as fh:
                rows = list(csv.reader(fh))

            self.assertEqual(len(rows), 3)  # header + 2 signals
            self.assertEqual(rows[1][0], "2026-08-04T00:00:00Z")
            self.assertEqual(rows[1][6], "Speed_Kmh")
            self.assertEqual(rows[1][7], "31.5")
            self.assertEqual(rows[2][6], "Voltage_780")

    def test_session_message_writes_sessions_csv(self):
        with tempfile.TemporaryDirectory() as root:
            sink = mod.CsvSink(root)
            mod.on_message(
                None,
                {"sink": sink},
                _FakeMsg(mod.TOPIC_SESSIONS, {"uid": "abc", "session_name": "RUN_1"}),
            )
            sink.close()

            path = os.path.join(root, "sessions.csv")
            with open(path, newline="", encoding="utf-8") as fh:
                rows = list(csv.reader(fh))

            self.assertEqual(rows[0], mod.SESSION_COLUMNS)
            self.assertEqual(rows[1][0], "abc")
            self.assertEqual(rows[1][1], "RUN_1")


if __name__ == "__main__":
    unittest.main()
