"""Recovery checks must detect content corruption, not just missing identities."""
import json
from pathlib import Path
import tempfile
import unittest
import csv
import io
import os
import sys
from contextlib import redirect_stdout
from unittest.mock import patch

from reconcile_telemetry import reconcile
from replay_csv import records, main as replay
from initialize_backend import main as initialize


class RecoveryToolsTest(unittest.TestCase):
    def setUp(self):
        self.event = json.loads((Path(__file__).resolve().parents[1] /
                                'test/fixtures/telemetry_v2_events.json').read_text())['events'][0]

    def test_sql_and_csv_representations_compare_equally(self):
        sql = dict(self.event, time='2026-10-06 01:00:00+00:00',
                   observed_at='2026-10-06 01:00:00+00:00', freshness_ms=5000,
                   can_id=None, source_sample_id=None, received_at='2026-10-07T00:00:00Z')
        for key in ('schema_version', 'ts_wall_utc', 'observed_at_utc'):
            sql.pop(key)
        archive = {k: str(v) for k, v in self.event.items()}
        archive['can_id'] = ''
        result = reconcile([self.event], [sql, archive])
        self.assertEqual(result['conflicts'], [])
        self.assertEqual(result['duplicates'], 1)

    def test_every_immutable_context_difference_is_a_conflict(self):
        for field, value in {'lap_number': 2, 'unit': 'A', 'source': 'phone_gps',
                             'quality': 'invalid', 'sample_kind': 'snapshot',
                             'observed_at_utc': '2026-10-06T01:00:01Z',
                             'ts_session_ms': 1, 'can_id': 123,
                             'source_sample_id': 'other-fix', 'freshness_ms': 999,
                             'session_state': 'ENDED', 'lap_phase': 'STOPPED'}.items():
            with self.subTest(field=field):
                self.assertTrue(reconcile([self.event], [dict(self.event, **{field: value})])['conflicts'])

    def test_conflicting_expected_archive_is_not_silently_overwritten(self):
        with self.assertRaises(ValueError):
            reconcile([self.event, dict(self.event, value=99)], [self.event])

    def test_replay_matches_uuid_case_and_keeps_original_identity(self):
        event = dict(self.event, session_uid='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa')
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'events.csv'
            with path.open('w', newline='', encoding='utf-8') as stream:
                writer = csv.DictWriter(stream, fieldnames=event.keys())
                writer.writeheader()
                writer.writerow(event)
            result = records([path], event['session_uid'].upper())
        self.assertEqual(len(result), 1)
        self.assertEqual(next(iter(result.values()))['ts_wall_utc'], event['ts_wall_utc'])

    def test_replay_refuses_conflicting_sql_before_publishing(self):
        with tempfile.TemporaryDirectory() as directory:
            paths = [Path(directory) / name for name in ['events.csv', 'sql.csv']]
            for path, event in zip(paths, [self.event, dict(self.event, lap_number=2)]):
                with path.open('w', newline='', encoding='utf-8') as stream:
                    writer = csv.DictWriter(stream, fieldnames=event.keys())
                    writer.writeheader()
                    writer.writerow(event)
            with patch.object(sys, 'argv', ['replay_csv.py', str(paths[0]), '--session',
                              self.event['session_uid'], '--sql-snapshot', str(paths[1]),
                              '--publish', '--host', 'unused.invalid']), redirect_stdout(io.StringIO()):
                with self.assertRaisesRegex(ValueError, 'SQL contains conflicting identity'):
                    replay()

    def test_bootstrap_missing_password_does_not_create_schema(self):
        with patch.dict(os.environ, {}, clear=True), patch('initialize_backend.subprocess.run') as run:
            with self.assertRaises(KeyError):
                initialize()
            run.assert_not_called()


if __name__ == '__main__':
    unittest.main()
