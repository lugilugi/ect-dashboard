import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:telemetry_dashboard/models/session/session_models.dart';
import 'package:telemetry_dashboard/models/telemetry/can_bindings.dart';
import 'package:telemetry_dashboard/models/telemetry/can_decoder.dart';
import 'package:telemetry_dashboard/services/location/gps_source_manager.dart';
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
  test(
    'distance crossing reading closes the old lap before subsequent samples',
    () async {
      final recorder = TelemetryRecorder(state, journal: journal);
      await recorder.start();
      state.setLapDividerMode(LapDividerMode.distance);
      state.setDistanceLapDividerKm(0.25);
      state.startSession('boundary');
      final bindings = CanBindings(state, recorder, GpsSourceManager(state));
      for (final raw in [0, 2600]) {
        final message = decodeCanFrame(
          CanIds.vehicleMotion,
          Uint8List.fromList([0, 0, raw & 255, raw >> 8, 0, 0, 1, 1]),
        )!;
        bindings.handle(message, receivedAtUtc: DateTime.now().toUtc());
      }
      await recorder.stop();
      final crossing = (await journal.readPending()).firstWhere(
        (r) =>
            r.record.payload['signal_name'] == 'Distance_Km' &&
            r.record.payload['value'] == 0.26,
      );
      expect(state.lapNumber, 2);
      expect(crossing.record.payload['lap_number'], 1);
    },
  );
  test(
    'restart restores the captured session and never reuses a sequence',
    () async {
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
      expect(
        (await journal.readPending())
            .where((r) => r.record.payload['signal_name'] == 'Recovery_Resumed')
            .length,
        1,
      );
    },
  );
  test(
    'capture overflow preserves final metadata and records explicit loss',
    () async {
      final recorder = TelemetryRecorder(state, journal: journal);
      await recorder.start();
      state.startSession('overflow');
      for (var value = 0; value < 400; value++) {
        recorder.record('Voltage_780', value.toDouble(), unit: 'V');
      }
      state.stopSession();
      await recorder.stop();
      final records = await journal.readPending(limit: 1000);
      expect(
        records.any(
          (r) =>
              r.record.payload['session_state'] == 'ENDED' &&
              r.record.payload.containsKey('uid'),
        ),
        isTrue,
      );
      expect(
        records.any((r) => r.record.payload['signal_name'] == 'Recording_Loss'),
        isTrue,
      );
      expect(await journal.readCheckpoint(), isNull);
      expect(journal.spoolHealth.rejectedRecordCount, greaterThan(0));
    },
  );
  test(
    'unavailable temperature and battery cell signals have no numeric placeholder',
    () {
      expect(state.mcTempC.isNaN, isTrue);
      expect(state.battTempC.isNaN, isTrue);
      expect(state.bmsCells.every((v) => v.isNaN), isTrue);
    },
  );
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
