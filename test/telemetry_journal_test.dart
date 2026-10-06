import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:telemetry_dashboard/models/session/session_models.dart';
import 'package:telemetry_dashboard/models/telemetry/journal_record.dart';
import 'package:telemetry_dashboard/models/telemetry/telemetry_event.dart';
import 'package:telemetry_dashboard/services/persistence/telemetry_journal.dart';
import 'package:telemetry_dashboard/services/persistence/readable_local_copy_writer.dart';

class FailedExportWriter extends ReadableLocalCopyWriter {
  @override
  Future<String?> appendRecord(Map<String, Object?> record) async {
    throw StateError('simulated file write failure');
  }
}

TelemetryRecord metric(int seq) => TelemetryRecord.metric(
  DecodedMetricEvent(
    metricKey: 'Voltage_780',
    value: 72.4,
    sessionId: '11111111-1111-4111-8111-111111111111',
    lapNumber: 1,
    sessionState: SessionState.logging,
    lapPhase: LapPhase.running,
    tsWallUtc: DateTime.utc(2026, 10, 6),
    tsSessionMs: 0,
    source: 'can',
    seqInSession: seq,
  ),
);

void main() {
  setUpAll(sqfliteFfiInit);
  test(
    'old telemetry format resets once and subsequent restart preserves new rows',
    () async {
      final dir = await Directory.systemTemp.createTemp('ect-format-test-');
      addTearDown(() async => dir.delete(recursive: true));
      final path = '${dir.path}/journal.db';
      final old = await databaseFactoryFfi.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: 3,
          onCreate: (db, version) async {
            await db.execute('CREATE TABLE decoded_events (seq INTEGER)');
            await db.insert('decoded_events', {'seq': 100});
          },
        ),
      );
      await old.close();
      var journal = TelemetryJournal(
        databasePath: path,
        factory: databaseFactoryFfi,
        readableCopyEnabled: false,
      );
      await journal.initialize();
      expect(await journal.readPending(), isEmpty);
      expect(await journal.maxSequence(metric(1).sessionId), 0);
      await journal.appendRecords([metric(1)]);
      await journal.close();
      journal = TelemetryJournal(
        databasePath: path,
        factory: databaseFactoryFfi,
        readableCopyEnabled: false,
      );
      expect((await journal.readPending()).single.record.identityNumber, 1);
      await journal.close();
    },
  );
  test(
    'quota rejection is visible and does not reuse the rejected identity',
    () async {
      final dir = await Directory.systemTemp.createTemp('ect-quota-test-');
      addTearDown(() async => dir.delete(recursive: true));
      final journal = TelemetryJournal(
        databasePath: '${dir.path}/journal.db',
        factory: databaseFactoryFfi,
        readableCopyEnabled: false,
        maxPendingBytes: 20,
      );
      addTearDown(journal.close);
      await expectLater(journal.appendRecords([metric(1)]), throwsStateError);
      expect(await journal.readPending(), isEmpty);
      expect(journal.spoolHealth.storageError, contains('budget'));
      expect(journal.spoolHealth.rejectedRecordCount, 1);
      expect(await journal.maxSequence(metric(1).sessionId), 1);
      await journal.close();
    },
  );
  test('ending metadata and checkpoint clear commit together', () async {
    final dir = await Directory.systemTemp.createTemp('ect-end-test-');
    addTearDown(() async => dir.delete(recursive: true));
    final journal = TelemetryJournal(
      databasePath: '${dir.path}/journal.db',
      factory: databaseFactoryFfi,
      readableCopyEnabled: false,
    );
    final id = metric(1).sessionId;
    await journal.appendRecords([metric(1)], checkpointJson: '{"active":true}');
    await journal.appendRecords([
      TelemetryRecord.session({
        'schema_version': 2,
        'uid': id,
        'metadata_revision': 2,
        'session_name': 'ended',
        'session_state': 'ENDED',
        'started_at_utc': '2026-10-06T00:00:00Z',
        'ended_at_utc': '2026-10-06T00:00:10Z',
        'laps_completed': 1,
      }),
    ], checkpointJson: null);
    expect(await journal.readCheckpoint(), isNull);
    expect(
      (await journal.readPending()).last.record.payload['session_state'],
      'ENDED',
    );
    expect(await journal.maxRevision(id), 2);
    await journal.close();
  });
  test(
    'unexported acknowledged rows survive pruning and repair CSV on restart',
    () async {
      final dir = await Directory.systemTemp.createTemp('ect-export-test-');
      addTearDown(() async => dir.delete(recursive: true));
      final path = '${dir.path}/journal.db';
      var journal = TelemetryJournal(
        databasePath: path,
        factory: databaseFactoryFfi,
        writer: FailedExportWriter(),
      );
      await journal.appendRecords([metric(1)]);
      final pending = await journal.readPending();
      await journal.markBrokerAcknowledged([pending.single.id]);
      await journal.prune(history: const Duration(seconds: -1));
      await expectLater(journal.flushExports(), throwsStateError);
      expect(journal.spoolHealth.exportError, contains('simulated'));
      await journal.close();
      journal = TelemetryJournal(
        databasePath: path,
        factory: databaseFactoryFfi,
      );
      await journal.flushExports();
      final files = await Directory(
        '${dir.path}/session_csv_v2',
      ).list().toList();
      final content = await (files.single as File).readAsLines();
      expect(content.length, 2);
      expect(content.first, contains('observed_at_utc'));
      expect(content.last, contains('72.4'));
      await journal.flushExports();
      expect((await (files.single as File).readAsLines()).length, 2);
      await journal.prune(history: const Duration(seconds: -1));
      expect(await journal.maxSequence(metric(1).sessionId), 1);
      await journal.close();
    },
  );
  test(
    'committed pending records and checkpoint survive reopening real SQLite',
    () async {
      final dir = await Directory.systemTemp.createTemp('ect-journal-test-');
      addTearDown(() async => dir.delete(recursive: true));
      final path = '${dir.path}/journal.db';
      var journal = TelemetryJournal(
        databasePath: path,
        factory: databaseFactoryFfi,
        readableCopyEnabled: false,
      );
      await journal.appendRecords([
        metric(1),
      ], checkpointJson: '{"last_seq_in_session":1}');
      await journal.close();
      journal = TelemetryJournal(
        databasePath: path,
        factory: databaseFactoryFfi,
        readableCopyEnabled: false,
      );
      final records = await journal.readPending();
      expect(records.single.record.payload['value'], 72.4);
      expect(await journal.readCheckpoint(), '{"last_seq_in_session":1}');
      await journal.markBrokerAcknowledged([records.single.id]);
      expect(await journal.readPending(), isEmpty);
      expect(await journal.maxSequence(metric(1).sessionId), 1);
      await journal.close();
    },
  );
}
