import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry_dashboard/models/telemetry/can_bindings.dart';
import 'package:telemetry_dashboard/models/telemetry/can_decoder.dart';
import 'package:telemetry_dashboard/providers/dashboard_state.dart';
import 'package:telemetry_dashboard/services/location/gps_source_manager.dart';
import 'package:telemetry_dashboard/services/persistence/local_spool_service.dart';
import 'package:telemetry_dashboard/services/transport/mqtt_service.dart';

class _NoopMqttTransport implements MqttTransport {
  void Function()? _onConnected;
  void Function()? _onDisconnected;

  @override
  set onConnected(void Function()? callback) {
    _onConnected = callback;
  }

  @override
  set onDisconnected(void Function()? callback) {
    _onDisconnected = callback;
  }

  @override
  Future<void> connect() async {
    _onConnected?.call();
  }

  @override
  void disconnect() {
    _onDisconnected?.call();
  }

  @override
  bool get isConnected => false;

  @override
  Future<bool> publish({
    required String topic,
    required String payloadJson,
  }) async {
    return false;
  }
}

class _BindingHarness {
  final DashboardState state = DashboardState();
  late final LocalSpoolService spool;
  late final MqttService mqtt;
  late final CanBindings bindings;

  _BindingHarness() {
    spool = LocalSpoolService(forceInMemory: true);
    mqtt = MqttService(
      state,
      localSpoolService: spool,
      transport: _NoopMqttTransport(),
    );
    bindings = CanBindings(state, mqtt, GpsSourceManager(state));
  }

  Future<void> dispose() async {
    await mqtt.stop();
    await spool.close();
    state.dispose();
  }
}

DecodedCanMessage _decode(int canId, List<int> bytes) {
  final message = decodeCanFrame(canId, Uint8List.fromList(bytes));
  expect(message, isNotNull);
  return message!;
}

List<int> _u16(int value) {
  return <int>[value & 0xff, (value >> 8) & 0xff];
}

List<int> _u32(int value) {
  return <int>[
    value & 0xff,
    (value >> 8) & 0xff,
    (value >> 16) & 0xff,
    (value >> 24) & 0xff,
  ];
}

void main() {
  test('routes primary DBC frames into DashboardState', () async {
    final harness = _BindingHarness();
    addTearDown(harness.dispose);

    harness.bindings.handle(
      _decode(CanIds.pedalStatus, <int>[0x00, 0x40, 0x04, 0, 0, 0]),
      receivedAtUtc: DateTime.utc(2026, 1, 1),
    );
    harness.bindings.handle(
      _decode(CanIds.packPower, <int>[..._u16(3840), ..._u16(500)]),
      receivedAtUtc: DateTime.utc(2026, 1, 1),
    );
    harness.bindings.handle(
      _decode(CanIds.auxPower, <int>[..._u16(3968), ..._u16(1250)]),
      receivedAtUtc: DateTime.utc(2026, 1, 1),
    );
    harness.bindings.handle(
      _decode(CanIds.vehicleMotion, <int>[
        ..._u16(5000),
        ..._u32(12345),
        0x01,
        0x03,
      ]),
      receivedAtUtc: DateTime.utc(2026, 1, 1),
    );

    expect(harness.state.throttlePercent, closeTo(50.0015, 0.0001));
    expect(harness.state.isBrakePressed, isTrue);
    expect(harness.state.mainVoltage, closeTo(12.0, 0.000001));
    expect(harness.state.current780, closeTo(1.2, 0.000001));
    expect(harness.state.bus12V, closeTo(12.4, 0.000001));
    expect(harness.state.current740, closeTo(1.5, 0.000001));
    expect(harness.state.speedKmh, closeTo(50.0, 0.000001));
    expect(harness.state.distanceKm, closeTo(1.2345, 0.000001));
  });

  test(
    'routes auxiliary commands and motor faults through app policy',
    () async {
      final harness = _BindingHarness();
      addTearDown(harness.dispose);

      harness.bindings.handle(
        _decode(CanIds.auxCommand, <int>[0x7B]),
        receivedAtUtc: DateTime.utc(2026, 1, 1),
      );
      harness.bindings.handle(
        _decode(CanIds.motorFaults, <int>[..._u32(1), ..._u32(2)]),
        receivedAtUtc: DateTime.utc(2026, 1, 1),
      );

      expect(harness.state.leftTurn, isTrue);
      expect(harness.state.rightTurn, isTrue);
      expect(harness.state.headlights, isTrue);
      expect(harness.state.hazards, isTrue);
      expect(harness.state.horn, isTrue);
      expect(harness.state.wipers, isTrue);
      expect(harness.state.errorCount, 2);
      expect(harness.state.lastErrorCode, 'MC_FAULT_FLAGS');
      expect(harness.state.mcFaults, <String>[
        'FAULT_FLAGS:0x00000001',
        'SW_FAULTS:0x00000002',
      ]);
    },
  );

  test(
    'emits a GPS sample only after status, position, and motion are valid',
    () async {
      final harness = _BindingHarness();
      addTearDown(harness.dispose);
      final timestamp = DateTime.utc(2026, 1, 1, 12);

      harness.bindings.handle(
        _decode(CanIds.gpsPosition, <int>[
          ..._u32(145660000),
          ..._u32(1209940000),
        ]),
        receivedAtUtc: timestamp,
      );
      expect(harness.state.lastKnownLat, isNull);

      harness.bindings.handle(
        _decode(CanIds.gpsStatus, <int>[11, 0x0D, 1, 0]),
        receivedAtUtc: timestamp,
      );
      expect(harness.state.lastKnownLat, isNull);

      harness.bindings.handle(
        _decode(CanIds.gpsMotion, <int>[..._u16(3200), ..._u16(1234)]),
        receivedAtUtc: timestamp,
      );

      expect(harness.state.gpsSatellites, 11);
      expect(harness.state.gpsLocked, isTrue);
      expect(harness.state.lastKnownLat, closeTo(14.566, 0.0000001));
      expect(harness.state.lastKnownLon, closeTo(120.994, 0.0000001));
      expect(harness.state.currentGpsSpeedKmh, closeTo(32.0, 0.000001));
      expect(harness.state.currentGpsHeadingDeg, closeTo(12.34, 0.000001));
      expect(harness.state.currentGpsSource, 'external_gps');
    },
  );
}
