import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:telemetry_dashboard/providers/dashboard_state.dart';
import 'package:telemetry_dashboard/services/orchestration/telemetry_recorder.dart';
import 'package:telemetry_dashboard/services/persistence/telemetry_journal.dart';
import 'package:telemetry_dashboard/services/transport/mqtt_service.dart';

class ControlledTransport implements MqttTransport {
  bool connected = true;
  final packets = <String>[];
  final acknowledgements = <Completer<bool>>[];
  @override
  bool get isConnected => connected;
  @override
  set onConnected(void Function()? callback) {}
  @override
  set onDisconnected(void Function()? callback) {}
  @override
  Future<void> connect() async {}
  @override
  void disconnect() {
    connected = false;
    for (final ack in acknowledgements) {
      if (!ack.isCompleted) ack.complete(false);
    }
  }

  @override
  Future<bool> publish({required String topic, required String payloadJson}) {
    packets.add(payloadJson);
    final ack = Completer<bool>();
    acknowledgements.add(ack);
    return ack.future;
  }
}

void main() {
  setUpAll(sqfliteFfiInit);
  late Directory dir;
  late DashboardState state;
  late TelemetryJournal journal;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('ect-pipeline-');
    state = DashboardState();
    journal = TelemetryJournal(
      databasePath: '${dir.path}/journal.db',
      factory: databaseFactoryFfi,
      readableCopyEnabled: false,
    );
  });
  tearDown(() async {
    state.dispose();
    await journal.close();
    await dir.delete(recursive: true);
  });
  test('restart restores the captured session and never reuses a sequence', () async {
    var recorder = TelemetryRecorder(state, journal: journal);
    await recorder.start();
    state.startSession('recover');
    final uid = state.sessionId;
    recorder.record('Voltage_780', 72, unit: 'V');
    await recorder.stop();
    final sequence = recorder.sequence;
    state.resetSessionState();
    recorder = TelemetryRecorder(state, journal: journal);
    await recorder.start();
    expect(state.sessionId, uid);
    expect(state.isLogging, isTrue);
    expect(recorder.sequence, sequence + 1);
    final event = recorder.record('Voltage_780', 71, unit: 'V')!;
    expect(event.seqInSession, sequence + 2);
    await recorder.stop();
    expect((await journal.readPending()).where((r) =>
      r.record.payload['signal_name'] == 'Recovery_Resumed').length, 1);
  });
  test(
    'offline final metadata clears recovery atomically; restart retains backlog',
    () async {
      final recorder = TelemetryRecorder(state, journal: journal);
      await recorder.start();
      state.startSession('offline');
      recorder.record('Voltage_780', 72, unit: 'V');
      await recorder.flush();
      expect(await journal.readCheckpoint(), isNotNull);
      state.updateMqttBacklog(count: 100, oldestEnqueuedAtUtc: DateTime.now());
      state.recordRecoveryResume();
      expect(state.stopSession(), isTrue);
      await recorder.stop();
      expect(await journal.readCheckpoint(), isNull);
      final finalMetadata = (await journal.readPending()).last.record.payload;
      expect(finalMetadata['session_state'], 'ENDED');
      expect(finalMetadata['ended_at_utc'], isNotNull);
      await journal.close();
      journal = TelemetryJournal(
        databasePath: '${dir.path}/journal.db',
        factory: databaseFactoryFfi,
        readableCopyEnabled: false,
      );
      expect((await journal.readPending()).length, greaterThan(1));
    },
  );
  test(
    'PUBACK is the only handoff; failed send replays identical context',
    () async {
      state.startSession('ack');
      final recorder = TelemetryRecorder(state, journal: journal);
      recorder.record('Voltage_780', 72, unit: 'V');
      recorder.record('Voltage_780', 71, unit: 'V');
      await recorder.flush();
      final transport = ControlledTransport();
      final sender = MqttService(state, journal: journal, transport: transport);
      var send = sender.flush();
      while (transport.packets.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect((await journal.readPending()).length, 2);
      transport.acknowledgements.last.complete(false);
      await send;
      final original = transport.packets.single;
      send = sender.flush();
      while (transport.packets.length < 2) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(transport.packets.last, original);
      final payload = jsonDecode(original) as Map<String, dynamic>;
      expect((payload['events'] as List).length, 2);
      transport.acknowledgements.last.complete(true);
      await send;
      expect(await journal.readPending(), isEmpty);
      await sender.stop();
    },
  );
}
