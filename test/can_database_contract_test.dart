import 'package:flutter_test/flutter_test.dart';
import 'package:telemetry_dashboard/models/telemetry/can_bindings.dart';
import 'package:telemetry_dashboard/models/telemetry/can_decoder.dart';
import 'package:telemetry_dashboard/models/telemetry/can_dictionary.dart';

void main() {
  test('every generated message has a unique standard CAN ID', () {
    final ids = CanDatabase.messages.map((message) => message.canId).toSet();

    expect(ids, hasLength(CanDatabase.messages.length));
    expect(
      CanDatabase.messages.every((message) => !message.isExtendedFrame),
      isTrue,
    );
  });

  test('generated cycle metadata reaches the app CAN dictionary', () {
    final pedal = CanDictionary.entries.singleWhere(
      (entry) => entry.canId == CanIds.pedalStatus,
    );

    expect(pedal.key, 'PEDAL_STATUS');
    expect(pedal.expectedDlc, 6);
    expect(pedal.cycleTimeMs, 20);
    expect(pedal.direction, 'PDLB -> IMC, LIBO');
  });

  test('application bindings preserve historical metric conversions', () {
    final throttle = canTelemetryBindingFor(
      CanIds.pedalStatus,
      'throttle_command',
    );
    final distance = canTelemetryBindingFor(
      CanIds.vehicleMotion,
      'trip_distance_m',
    );

    expect(throttle, isNotNull);
    expect(throttle!.metricName, 'Throttle_Percent');
    expect(throttle.transformValue(16383.5), closeTo(50.0, 0.01));
    final deadman = canTelemetryBindingFor(
      CanIds.pedalStatus,
      'deadman_active',
    );
    expect(deadman, isNotNull);
    expect(deadman!.metricName, 'Deadman_Active');
    expect(distance, isNotNull);
    expect(distance!.metricName, 'Distance_Km');
    expect(distance.transformValue(1234.0), closeTo(1.234, 0.000001));
  });
}
