import csv
import json
import pathlib
import tempfile
import unittest

import csv_streamer as mod

FIXTURES = pathlib.Path(__file__).resolve().parents[2] / "test" / "fixtures"


class Message:
    def __init__(self, topic, payload):
        self.topic = topic
        self.payload = json.dumps(payload).encode()


class ContractTest(unittest.TestCase):
    def payload(self):
        return json.loads((FIXTURES / "telemetry_v2_events.json").read_text())

    def test_repeated_signal_retains_individual_time_and_lap(self):
        payload = json.loads((FIXTURES / "telemetry_v2_events.json").read_text())
        with tempfile.TemporaryDirectory() as root:
            sink = mod.CsvSink(root)
            mod.on_message(None, {"sink": sink}, Message(mod.TOPIC_EVENTS, payload))
            sink.close()
            file = pathlib.Path(root) / "events_v2_11111111-1111-4111-8111-111111111111.csv"
            with file.open(newline="") as stream:
                rows = list(csv.DictReader(stream))
            self.assertEqual([r["value"] for r in rows], ["72.4", "71.9"])
            self.assertEqual([r["lap_number"] for r in rows], ["1", "2"])
            self.assertEqual(rows[1]["seq_in_session"], "2")
            self.assertEqual(rows[1]["ts_wall_utc"], "2026-10-06T01:00:00.100000Z")

    def test_bad_record_does_not_block_valid_neighbor(self):
        payload = self.payload()
        payload["events"][0]["session_uid"] = ["malformed"]
        with tempfile.TemporaryDirectory() as root:
            sink = mod.CsvSink(root)
            mod.on_message(None, {"sink": sink}, Message(mod.TOPIC_EVENTS, payload))
            sink.close()
            with (pathlib.Path(root) / "rejected_v2.csv").open(newline="") as stream:
                self.assertEqual(len(list(csv.DictReader(stream))), 1)
            file = pathlib.Path(root) / "events_v2_11111111-1111-4111-8111-111111111111.csv"
            with file.open(newline="") as stream:
                self.assertEqual(len(list(csv.DictReader(stream))), 1)

    def test_redelivery_after_restart_keeps_identity_and_header(self):
        payload = self.payload()
        with tempfile.TemporaryDirectory() as root:
            for _ in range(2):
                sink = mod.CsvSink(root)
                mod.on_message(None, {"sink": sink}, Message(mod.TOPIC_EVENTS, payload))
                sink.close()
            file = pathlib.Path(root) / "events_v2_11111111-1111-4111-8111-111111111111.csv"
            with file.open(newline="") as stream:
                rows = list(csv.DictReader(stream))
            self.assertEqual(len(rows), 4)
            self.assertEqual({r["seq_in_session"] for r in rows}, {"1", "2"})
            self.assertEqual(rows[0], rows[2])

    def test_session_and_unsupported_version(self):
        payload = json.loads((FIXTURES / "telemetry_v2_session.json").read_text())
        with tempfile.TemporaryDirectory() as root:
            sink = mod.CsvSink(root)
            mod.on_message(None, {"sink": sink}, Message(mod.TOPIC_SESSIONS, payload))
            payload["schema_version"] = 1
            mod.on_message(None, {"sink": sink}, Message(mod.TOPIC_SESSIONS, payload))
            sink.close()
            with (pathlib.Path(root) / "sessions_v2.csv").open(newline="") as stream:
                rows = list(csv.DictReader(stream))
            self.assertEqual(rows[0]["session_name"], "contract-fixture")
            self.assertEqual(rows[0]["metadata_revision"], "1")
            self.assertTrue((pathlib.Path(root) / "rejected_v2.csv").exists())


if __name__ == "__main__":
    unittest.main()
