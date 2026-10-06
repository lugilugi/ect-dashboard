import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';
import 'package:telemetry_dashboard/models/telemetry/can_bindings.dart';
import 'package:telemetry_dashboard/models/telemetry/can_decoder.dart';
import 'package:telemetry_dashboard/providers/dashboard_state.dart';
import 'package:telemetry_dashboard/services/location/gps_source_manager.dart';
import 'package:telemetry_dashboard/services/orchestration/telemetry_recorder.dart';
import 'package:telemetry_dashboard/services/persistence/telemetry_journal.dart';
import 'package:telemetry_dashboard/services/transport/mqtt_service.dart';

void main() {
  final port = int.tryParse(Platform.environment['ECT_TEST_MQTT_PORT'] ?? '');
  test(
    'CAN decode → recorder → SQLite → actual MQTT PUBACK',
    () async {
      sqfliteFfiInit();
      final dir = Directory(Platform.environment['ECT_TEST_OUTPUT']!);
      await dir.create(recursive: true);
      final state = DashboardState();
      final journal = TelemetryJournal(
        databasePath: '${dir.path}/phone.db',
        factory: databaseFactoryFfi,
        readableCopyDirectoryPath: '${dir.path}/csv',
      );
      final recorder = TelemetryRecorder(state, journal: journal);
      final transport = MqttServerClientTransport(
        host: '127.0.0.1',
        port: port!,
        clientId: 'ect-qualification-${const Uuid().v4()}',
      );
      final sender = MqttService(state, journal: journal, transport: transport);
      addTearDown(() async {
        await recorder.stop();
        await sender.stop();
        state.dispose();
        await journal.close();
      });
      await recorder.start();
      state.startSession('Automated CAN pipeline');
      final bindings = CanBindings(state, recorder, GpsSourceManager(state));
      for (var i = 0; i < 40; i++) {
        final voltage = 19200 + i;
        final decoded = decodeCanFrame(
          CanIds.packPower,
          Uint8List.fromList([voltage & 255, voltage >> 8, 0xd0, 0x07]),
        )!;
        bindings.handle(decoded, receivedAtUtc: DateTime.now().toUtc());
      }
      expect(state.mainVoltage, closeTo(60.121875, 0.000001));
      expect(state.stopSession(), isTrue);
      await recorder.stop();
      final records = await journal.readPending(limit: 10000);
      await File('${dir.path}/expected.json').writeAsString(
        jsonEncode(records.map((r) => r.record.payload).toList()),
      );
      await journal.flushExports();
      await transport.connect();
      for (var attempt = 0; attempt < 20; attempt++) {
        await sender.flush();
        if ((await journal.readPending()).isEmpty) break;
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      expect(await journal.readPending(), isEmpty);
    },
    skip: port == null
        ? 'Run through tools/qualify_backend.py; hardware is separate.'
        : false,
  );
}
