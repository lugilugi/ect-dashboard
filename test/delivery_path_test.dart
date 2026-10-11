import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:telemetry_dashboard/models/session/session_models.dart';
import 'package:telemetry_dashboard/models/telemetry/journal_record.dart';
import 'package:telemetry_dashboard/models/telemetry/telemetry_event.dart';
import 'package:telemetry_dashboard/providers/dashboard_state.dart';
import 'package:telemetry_dashboard/services/orchestration/telemetry_recorder.dart';
import 'package:telemetry_dashboard/services/persistence/telemetry_journal.dart';
import 'package:telemetry_dashboard/services/transport/mqtt_service.dart';

const _session = '22222222-2222-4222-8222-222222222222';

TelemetryRecord metric(int seq, {double value = 72.4}) =>
    TelemetryRecord.metric(
      DecodedMetricEvent(
        metricKey: 'Voltage_780',
        value: value,
        sessionId: _session,
        lapNumber: 1,
        sessionState: SessionState.logging,
        lapPhase: LapPhase.running,
        tsWallUtc: DateTime.utc(2026, 10, 6),
        tsSessionMs: 0,
        source: 'can',
        seqInSession: seq,
      ),
    );

TelemetryRecord sessionRecord(int revision) => TelemetryRecord.session({
  'schema_version': 2,
  'uid': _session,
  'session_name': 'delivery',
  'started_at_utc': '2026-10-06T00:00:00.000Z',
  'session_state': 'logging',
  'laps_completed': 0,
  'metadata_revision': revision,
});

/// Publishes are held until the test completes their acknowledgement.
class HeldTransport implements MqttTransport {
  final packets = <String>[];
  final acks = <Completer<bool>>[];
  @override
  bool get isConnected => true;
  @override
  set onConnected(void Function()? callback) {}
  @override
  set onDisconnected(void Function()? callback) {}
  @override
  Future<void> connect() async {}
  @override
  void disconnect() {}
  @override
  Future<bool> publish({required String topic, required String payloadJson}) {
    packets.add(payloadJson);
    final ack = Completer<bool>();
    acks.add(ack);
    return ack.future;
  }
}

void main() {
  setUpAll(sqfliteFfiInit);
  late Directory dir;
  final open = <TelemetryJournal>[];
  TelemetryJournal journalAt({int maxPendingBytes = 256 * 1024 * 1024}) {
    final journal = TelemetryJournal(
      databasePath: '${dir.path}/journal.db',
      factory: databaseFactoryFfi,
      readableCopyEnabled: false,
      maxPendingBytes: maxPendingBytes,
    );
    open.add(journal);
    return journal;
  }

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('ect-delivery-');
  });
  tearDown(() async {
    for (final journal in open) {
      await journal.close();
    }
    open.clear();
    await dir.delete(recursive: true);
  });

  test('incremental backlog accounting matches a full recount', () async {
    final journal = journalAt();
    await journal.appendRecords([for (var i = 1; i <= 10; i++) metric(i)]);
    // Duplicate and conflict in one append; the new record still commits.
    final result = await journal.appendRecords([
      metric(1),
      metric(2, value: 1),
      metric(11),
    ]);
    expect(result.stored, 1);
    expect(result.duplicates, 1);
    expect(result.conflicts, [metric(2).key]);
    expect(journal.failedRecordCount, 1);
    final pending = await journal.readPending(limit: 100);
    await journal.recordDeliveryRound(
      acked: [pending[0].id, pending[3].id],
      failed: [pending[1].id],
      error: 'PUBACK unavailable',
    );
    await journal.markDropped(pending[4].id, 'test');
    final count = journal.pendingCount;
    final bytes = journal.pendingBytes;
    expect(count, 8);
    await journal.close();
    final reopened = journalAt();
    await reopened.initialize();
    expect(reopened.pendingCount, count);
    expect(reopened.pendingBytes, bytes);
    expect(reopened.failedRecordCount, 1);
    expect(reopened.spoolHealth.oldestEnqueuedAtUtc, isNotNull);
  });

  test('quota rejection is one loss row; metadata is still stored', () async {
    final size = utf8ByteLength(metric(1).payloadJson);
    final journal = journalAt(maxPendingBytes: size * 2);
    final result = await journal.appendRecords([
      for (var i = 1; i <= 5; i++) metric(i),
      sessionRecord(1),
    ]);
    expect(result.stored, 3);
    expect(result.quotaRejected, 3);
    // Identities are consumed even when rejected.
    expect(await journal.maxSequence(_session), 5);
    expect(await journal.maxRevision(_session), 1);
    final pending = await journal.readPending();
    expect(
      pending.map((r) => r.record.kind),
      containsAll([TelemetryRecordKind.session, TelemetryRecordKind.metric]),
    );
    // Draining the backlog makes room again without any reset.
    await journal.recordDeliveryRound(acked: [for (final r in pending) r.id]);
    final resumed = await journal.appendRecords([metric(6)]);
    expect(resumed.stored, 1);
    expect(journal.spoolHealth.quotaRejectedRecordCount, 3);
  });

  test('v4 journal migrates to v5 without losing pending rows', () async {
    final path = '${dir.path}/journal.db';
    final legacy = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 4,
        onCreate: (db, _) async {
          await db.execute('''CREATE TABLE journal (
            id INTEGER PRIMARY KEY AUTOINCREMENT, record_key TEXT NOT NULL UNIQUE,
            kind TEXT NOT NULL, session_uid TEXT NOT NULL, identity_number INTEGER NOT NULL,
            payload_json TEXT NOT NULL, payload_bytes INTEGER NOT NULL,
            enqueued_at_utc TEXT NOT NULL, delivery_state TEXT NOT NULL DEFAULT 'pending',
            attempt_count INTEGER NOT NULL DEFAULT 0, last_error TEXT, broker_acked_at_utc TEXT
          )''');
          await db.execute(
            'CREATE INDEX journal_pending ON journal(delivery_state,id)',
          );
          await db.execute('''CREATE TABLE session_watermarks (
            session_uid TEXT PRIMARY KEY, sequence INTEGER NOT NULL DEFAULT 0,
            revision INTEGER NOT NULL DEFAULT 0
          )''');
          await db.execute(
            'CREATE TABLE control_checkpoint (id INTEGER PRIMARY KEY CHECK(id=1), json TEXT NOT NULL)',
          );
          await db.execute(
            'CREATE TABLE export_state (id INTEGER PRIMARY KEY CHECK(id=1), last_id INTEGER NOT NULL)',
          );
          await db.insert('export_state', {'id': 1, 'last_id': 0});
          await db.execute('''CREATE TABLE recording_losses (
            id INTEGER PRIMARY KEY AUTOINCREMENT, record_key TEXT NOT NULL,
            recorded_at_utc TEXT NOT NULL, reason TEXT NOT NULL
          )''');
        },
      ),
    );
    final record = metric(1);
    await legacy.insert('journal', {
      'record_key': record.key,
      'kind': record.kind.name,
      'session_uid': record.sessionId,
      'identity_number': 1,
      'payload_json': record.payloadJson,
      'payload_bytes': utf8ByteLength(record.payloadJson),
      'enqueued_at_utc': '2026-10-06T00:00:00.000Z',
    });
    await legacy.insert('session_watermarks', {
      'session_uid': _session,
      'sequence': 1,
    });
    await legacy.insert('control_checkpoint', {'id': 1, 'json': '{"a":1}'});
    await legacy.close();

    final size = utf8ByteLength(record.payloadJson);
    final journal = journalAt(maxPendingBytes: size);
    await journal.initialize();
    expect((await journal.readPending()).single.record.key, record.key);
    expect(journal.pendingCount, 1);
    expect(await journal.maxSequence(_session), 1);
    expect(await journal.readCheckpoint(), '{"a":1}');
    // New v5 columns/tables are usable: a quota loss row and a conflict.
    final result = await journal.appendRecords([
      metric(1, value: 3),
      metric(2),
    ]);
    expect(result.quotaRejected, 1);
    expect(result.conflicts, [record.key]);
  });

  test('recorder skips idle transactions and recovers after quota', () async {
    final state = DashboardState();
    addTearDown(state.dispose);
    final probe = TelemetryRecord.metric(
      DecodedMetricEvent(
        metricKey: 'Probe',
        value: 1,
        sessionId: _session,
        lapNumber: null,
        sessionState: SessionState.armed,
        lapPhase: LapPhase.running,
        tsWallUtc: DateTime.utc(2026, 10, 6),
        tsSessionMs: 0,
        source: 'app',
        seqInSession: 1,
      ),
    );
    final journal = journalAt(
      maxPendingBytes: 4096 + utf8ByteLength(probe.payloadJson) * 2,
    );
    final recorder = TelemetryRecorder(state, journal: journal);
    await recorder.start();
    final idle = recorder.appendCalls;
    await recorder.flush();
    await recorder.flush();
    expect(recorder.appendCalls, idle, reason: 'nothing changed');

    state.startSession('quota');
    for (var i = 0; i < 40; i++) {
      recorder.record('Probe', i.toDouble(), source: 'app', diagnostic: true);
    }
    await recorder.flush();
    expect(recorder.bufferedRecordCount, 0, reason: 'quota is terminal');
    final rejected = journal.spoolHealth.quotaRejectedRecordCount;
    expect(rejected, greaterThan(0));

    final pending = await journal.readPending(limit: 1000);
    await journal.recordDeliveryRound(acked: [for (final r in pending) r.id]);
    await recorder.flush();
    final after = await journal.readPending(limit: 1000);
    final loss = after
        .map((r) => r.record.payload)
        .where((p) => p['signal_name'] == 'Recording_Loss')
        .toList();
    expect(loss, hasLength(1));
    expect(loss.single['value'], rejected.toDouble());
    await recorder.stop();
  });

  test('sender publishes a bounded concurrent round and keeps acked '
      'siblings when one message fails', () async {
    final state = DashboardState();
    addTearDown(state.dispose);
    final journal = journalAt();
    await journal.appendRecords([
      for (var r = 1; r <= 4; r++) sessionRecord(r),
    ]);
    final transport = HeldTransport();
    final sender = MqttService(
      state,
      journal: journal,
      transport: transport,
      maxInFlight: 3,
    );
    final flushing = sender.flush();
    await pumpEventQueue();
    // Three in flight at once; the fourth waits for the round to finish.
    expect(transport.packets, hasLength(3));
    transport.acks[0].complete(true);
    transport.acks[1].complete(false);
    transport.acks[2].complete(true);
    await flushing;
    final pending = await journal.readPending();
    expect(pending.map((r) => r.record.identityNumber), [2, 4]);
    expect(pending.first.attempts, 1);
    expect(journal.pendingCount, 2);
  });
}
