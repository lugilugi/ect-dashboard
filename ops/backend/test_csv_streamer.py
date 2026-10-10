import json
import os
import tempfile
import unittest
from types import SimpleNamespace

import csv_streamer as cs


class FakeClient:
    def __init__(self):
        self.acked = []

    def ack(self, mid, qos):
        self.acked.append((mid, qos))

    def subscribe(self, topics):
        pass


class CsvStreamerAckTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.sink = cs.CsvSink(self.tmp.name)
        self.addCleanup(self.sink.close)
        self.flushes = 0
        real = self.sink.flush_all

        def counting():
            self.flushes += 1
            real()
        self.sink.flush_all = counting
        self.acks = cs.AckTracker(self.sink)
        self.data = {"sink": self.sink, "acks": self.acks}
        self.client = FakeClient()

    def msg(self, mid, qos=1):
        # Unsupported envelope: goes to rejected_v2.csv, still must be acked.
        body = json.dumps({"schema_version": 1}).encode()
        return SimpleNamespace(topic=cs.TOPIC_SESSIONS, payload=body, mid=mid, qos=qos)

    def test_not_acked_before_flush_acked_after(self):
        cs.on_connect(self.client, self.data, None, 0)
        cs.on_message(self.client, self.data, self.msg(1))
        cs.on_message(self.client, self.data, self.msg(2))
        self.assertEqual(self.client.acked, [])
        self.acks.flush_and_ack(self.client)
        self.assertEqual(self.client.acked, [(1, 1), (2, 1)])
        self.assertEqual(self.flushes, 1)
        self.acks.flush_and_ack(self.client)
        self.assertEqual(self.client.acked, [(1, 1), (2, 1)])

    def test_rows_on_disk_when_acked(self):
        cs.on_connect(self.client, self.data, None, 0)
        cs.on_message(self.client, self.data, self.msg(7))
        self.acks.flush_and_ack(self.client)
        path = os.path.join(self.tmp.name, "rejected_v2.csv")
        with open(path, encoding="utf-8") as f:
            self.assertEqual(len(f.read().splitlines()), 2)

    def test_no_ack_for_previous_connection(self):
        cs.on_connect(self.client, self.data, None, 0)
        cs.on_message(self.client, self.data, self.msg(1))
        cs.on_connect(self.client, self.data, None, 0)  # reconnect
        self.acks.flush_and_ack(self.client)
        self.assertEqual(self.client.acked, [])
        cs.on_message(self.client, self.data, self.msg(1))  # redelivery
        self.acks.flush_and_ack(self.client)
        self.assertEqual(self.client.acked, [(1, 1)])

    def test_qos0_not_acked(self):
        cs.on_connect(self.client, self.data, None, 0)
        cs.on_message(self.client, self.data, self.msg(3, qos=0))
        self.acks.flush_and_ack(self.client)
        self.assertEqual(self.client.acked, [])


if __name__ == "__main__":
    unittest.main()
